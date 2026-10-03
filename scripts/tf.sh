#!/usr/bin/env bash
# =============================================================================
# tf.sh — MiniStack / AWS を切り替えて Terraform を実行するラッパー
#
#   使い方: scripts/tf.sh <環境> <コマンド> [terraformへの追加引数...]
#
#     環境:
#       ministack  プロバイダ=MiniStack / state=MiniStack上のS3   （開発・お試し）
#       local      プロバイダ=MiniStack / state=ローカルファイル   （最初の試用向け）
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
#     1. 環境に応じた tfvars と backend 設定を選ぶ
#     2. ministack 環境なら -var で MiniStack ホストを注入（.env 由来）
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

# ---- 環境ごとの引数組み立て ---------------------------------------------------
BACKEND_ARGS=()
VAR_ARGS=()
NEEDS_VARS=0

case "$ENV" in
    ministack)
        BACKEND_ARGS=(
            -backend-config="envs/ministack.backend.hcl"
            -backend-config="endpoint=$(ms_endpoint)"
            -backend-config="dynamodb_endpoint=$(ms_endpoint)"
            -backend-config="sts_endpoint=$(ms_endpoint)"
            -backend-config="iam_endpoint=$(ms_endpoint)"
            -reconfigure
        )
        VAR_ARGS=(-var-file=envs/ministack.tfvars -var="ministack_host=$(ms_host)" -var="ministack_port=$(ms_port)")
        ;;
    aws)
        BACKEND_ARGS=(-backend-config=envs/aws.backend.hcl -reconfigure)
        VAR_ARGS=(-var-file=envs/aws.tfvars)
        # AWS_ENDPOINT_URL 等が export されたシェルから呼ばれても本物へ向くように掃除
        ;;
    local)
        BACKEND_ARGS=(-backend=false)
        VAR_ARGS=(-var-file=envs/ministack.tfvars -var="ministack_host=$(ms_host)" -var="ministack_port=$(ms_port)")
        ;;
esac

case "$ENV" in
    aws)
        # init（バックエンド接続）の前に認証を確認しておく
        if ! aws sts get-caller-identity >/dev/null 2>&1; then
            _ms_err "本物のAWS認証がありません（aws sts get-caller-identity が失敗）"
            _ms_err "aws sso login / 環境変数 / プロファイルを設定してから再実行してください"
            exit 1
        fi
        ;;
esac

# ---- terraform 実行前の環境整備 ----------------------------------------------
terraform_init() {
    _ms_log "terraform init ($ENV backend)"
    if ! terraform init -input=false "${BACKEND_ARGS[@]}" "$@" >/dev/null; then
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
}

case "$CMD" in
    init)
        terraform_init
        _ms_log "init 完了 ($ENV)"
        exit 0
        ;;
    plan|apply|destroy|refresh|import|plan-all|apply-all)
        NEEDS_VARS=1
        ;;
esac

# 初回、または前回とbackend環境が違う場合は init し直す
CURRENT_BACKEND="none"
[[ -f "$STAMP_FILE" ]] && CURRENT_BACKEND="$(cat "$STAMP_FILE")"
if [[ ! -d .terraform || "$CURRENT_BACKEND" != "$ENV" ]]; then
    terraform_init
fi

# ---- 実行 --------------------------------------------------------------------
case "$ENV" in
    ministack|local)
        # terraform プロセスにも MiniStack 向けの env を渡す（providers.tf の
        # エンドポイント指定と二重になるが、無害であって矛盾しない）
        ms_use
        ;;
    aws)
        ms_clear
        ;;
esac

if (( NEEDS_VARS )); then
    _ms_log "terraform $CMD ($ENV) ${VAR_ARGS[*]} $*"
    exec terraform "$CMD" -input=false "${VAR_ARGS[@]}" "$@"
else
    exec terraform "$CMD" "$@"
fi
