#!/usr/bin/env bash
# =============================================================================
# tf.sh — MiniStack / AWS を切り替えて Terraform を実行するラッパー
#
#   使い方: scripts/tf.sh <環境> <コマンド> [terraformへの追加引数...]
#
#     環境:
#       ministack  プロバイダ=MiniStack / state=MiniStack上のS3   （開発・お試し）
#       local      プロバイダ=MiniStack / state=ローカルファイル   （未initのディレクトリで最初に試す用）
#       aws        プロバイダ=本物のAWS  / state=AWSのS3+DynamoDB （本番）
#
#   例:
#     scripts/tf.sh ministack init
#     scripts/tf.sh ministack plan
#     scripts/tf.sh ministack apply
#     scripts/tf.sh aws plan              # AWS側にまだ何も無ければ差分=全リソース作成
#     scripts/tf.sh aws apply
#     scripts/tf.sh local plan            # backend無しで手軽に試す
#     scripts/tf.sh ministack destroy
#
#   スタック指定（base-stack 以外を作った場合）:
#     STACK=my-stack scripts/tf.sh ministack plan
#
#   このスクリプトがやること:
#     1. 環境に応じて、シェル環境（ms_use/ms_clear）を「最初に」切り替える
#     2. 環境に応じた tfvars と backend 設定を選ぶ（.env のホスト・リージョンを注入）
#     3. backend が前回と変わっていれば init -reconfigure（stateの移行は明示的に）
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/ministack.sh"

STACK="${STACK:-base-stack}"
STACK_DIR="$MS_ROOT/terraform/$STACK"
STAMP_FILE="$STACK_DIR/.terraform/.ms-backend"

usage() { sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 1; }

[[ $# -ge 2 ]] || usage
ENV="$1"; shift
CMD="$1"; shift || true

[[ "$ENV" == "ministack" || "$ENV" == "local" || "$ENV" == "aws" ]] || usage
[[ -d "$STACK_DIR" ]] || { _ms_err "スタックが見つかりません: $STACK_DIR"; exit 1; }
command -v terraform >/dev/null 2>&1 || { _ms_err "terraform が見つかりません"; exit 1; }

cd "$STACK_DIR"

# ---- 環境ごとの設定（シェル環境の切替を必ずinit/認証確認より先に行う） ----------
BACKEND_ARGS=()
VAR_ARGS=()
BACKEND_TYPE="s3"   # ministack/aws は s3、local は local

case "$ENV" in
    ministack)
        # terraform / init プロセスにも MiniStack 向け env を継承させる
        #（providers.tf のエンドポイント指定と二重になるが矛盾しない）
        ms_use
        BACKEND_ARGS=(
            -backend-config="envs/ministack.backend.hcl"
            -backend-config="endpoint=$(ms_endpoint)"
            -backend-config="dynamodb_endpoint=$(ms_endpoint)"
            -backend-config="sts_endpoint=$(ms_endpoint)"
            -backend-config="iam_endpoint=$(ms_endpoint)"
            -backend-config="region=$(ms_region)"
            -reconfigure
        )
        VAR_ARGS=(
            -var-file=envs/ministack.tfvars
            -var="ministack_host=$(ms_host)"
            -var="ministack_port=$(ms_port)"
            -var="aws_region=$(ms_region)"
        )
        ;;
    local)
        ms_use
        BACKEND_TYPE="local"
        # s3 backend でinit済みだった場合、stateはリモートに残ったまま
        # ローカルの空stateからやり直しになる（-reconfigure は移行しない）
        if [[ -f "$STAMP_FILE" && "$(cat "$STAMP_FILE")" != "local" ]]; then
            _ms_warn "$(cat "$STAMP_FILE") バックエンドから local へ切り替えます（リモートstateはそのまま残ります）"
        fi
        BACKEND_ARGS=(-reconfigure)
        VAR_ARGS=(
            -var-file=envs/ministack.tfvars
            -var="ministack_host=$(ms_host)"
            -var="ministack_port=$(ms_port)"
            -var="aws_region=$(ms_region)"
        )
        ;;
    aws)
        # 本番backendにテスト用のローカルstateが持ち込まれる事故を防ぐ（先にローカルチェック）。
        # 名前付き workspace の state（terraform.tfstate.d/*/terraform.tfstate）も対象。
        # -force-copy はworkspace stateも確認なしで移行し、同名のAWS側stateを
        # 上書きし得るため、非空のローカルstateがある時点で拒否する
        LOCAL_STATE=""
        [[ -s terraform.tfstate ]] && LOCAL_STATE="terraform.tfstate"
        if [[ -d terraform.tfstate.d ]]; then
            WS_STATE="$(find terraform.tfstate.d -type f -name 'terraform.tfstate' -size +0c 2>/dev/null | head -5 || true)"
            [[ -n "$WS_STATE" ]] && LOCAL_STATE="${LOCAL_STATE:+$LOCAL_STATE, }$WS_STATE"
        fi
        if [[ -n "$LOCAL_STATE" ]]; then
            _ms_err "ローカルに state が残っています: $LOCAL_STATE"
            _ms_err "aws バックエンドへは移行しません。以下のいずれかを行ってください:"
            _ms_err "  - 続行: mv terraform.tfstate terraform.tfstate.local-backup"
            _ms_err "  - local のリソースを片付ける: scripts/tf.sh local destroy"
            _ms_err "  - workspace の state を確認: terraform workspace list"
            exit 1
        fi
        # ms_use 済みのシェルから呼ばれても確実に本物へ向ける（認証確認・init の前に実行）
        ms_clear
        if ! aws sts get-caller-identity >/dev/null 2>&1; then
            _ms_err "本物のAWS認証がありません（aws sts get-caller-identity が失敗）"
            _ms_err "aws sso login / 環境変数 / プロファイルを設定してから再実行してください"
            exit 1
        fi
        BACKEND_ARGS=(-backend-config=envs/aws.backend.hcl -reconfigure)
        VAR_ARGS=(-var-file=envs/aws.tfvars)
        ;;
esac

# ---- バックエンド型のブロックを生成（local モードを確実に動かすため） ----------
# versions.tf に backend ブロックを書くと -backend=false でもplanが
# "Backend initialization required" で失敗するため、環境に応じてここで生成する。
BACKEND_TF="backend.generated.tf"
BACKEND_BLOCK=$(printf 'terraform {\n  backend "%s" {}\n}' "$BACKEND_TYPE")
if [[ ! -f "$BACKEND_TF" ]] || [[ "$(cat "$BACKEND_TF")" != "$BACKEND_BLOCK" ]]; then
    printf '%s\n' "$BACKEND_BLOCK" > "$BACKEND_TF"
fi

# ---- terraform 実行前の環境整備 ----------------------------------------------
terraform_init() {
    _ms_log "terraform init ($ENV backend)"
    # -force-copy: backendタイプ切替（local⇄s3）時の対話プロンプトを抑止する。
    #   挙動（実測）: タイプ切替時はローカルstateを移行し、
    #   同タイプ（ministack⇄aws）の接続先変更ではstateを移行しない（分離維持）
    local had_local_state=0
    if [[ -s terraform.tfstate ]]; then
        had_local_state=1
    fi
    if ! terraform init -input=false -reconfigure -force-copy "${BACKEND_ARGS[@]}" "$@" >/dev/null; then
        _ms_err "terraform init に失敗しました"
        if [[ "$ENV" == "aws" ]]; then
            _ms_err "ヒント: tfstate用バケット/テーブルは作成済みですか? -> scripts/bootstrap-backend.sh aws"
            _ms_err "ヒント: envs/aws.backend.hcl の bucket/region が正しいか確認してください"
        else
            _ms_err "ヒント: MiniStack は起動していますか? -> scripts/healthcheck.sh"
            _ms_err "ヒント: tfstate用バケットは作成済みですか? -> scripts/bootstrap-backend.sh ministack"
        fi
        exit 1
    fi
    mkdir -p .terraform
    echo "$ENV" > "$STAMP_FILE"
    if (( had_local_state )) && [[ "$BACKEND_TYPE" == "s3" ]]; then
        _ms_warn "ローカルにあった terraform.tfstate を ${ENV} バックエンドへ移行しました"
    fi
}

case "$CMD" in
    init)
        terraform_init
        _ms_log "init 完了 ($ENV)"
        exit 0
        ;;
    plan|apply|destroy|refresh|import)
        NEEDS_VARS=1
        ;;
esac

# 初回・切替・同一環境のいずれでも毎回 init する（遅いが数秒。
# 条件付きskipは「スタンプと実際のbackend設定の不整合」による事故を許すため採らない）
terraform_init

# ---- 実行 --------------------------------------------------------------------
if [[ "${NEEDS_VARS:-0}" == "1" ]]; then
    _ms_log "terraform $CMD ($ENV)"
    exec terraform "$CMD" -input=false "${VAR_ARGS[@]}" "$@"
else
    exec terraform "$CMD" "$@"
fi
