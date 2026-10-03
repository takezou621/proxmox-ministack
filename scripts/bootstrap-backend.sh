#!/usr/bin/env bash
# =============================================================================
# bootstrap-backend.sh — Terraform の S3バックエンド（state置き場）を初期作成する
#
#   使い方:
#     scripts/bootstrap-backend.sh ministack   # MiniStack上に tfstateバケット＋ロックテーブルを作成
#     scripts/bootstrap-backend.sh aws         # 本番AWS上に作成（要: 有効なAWS認証）
#
#   作成されるもの:
#     - S3バケット        proxmox-ministack-tfstate
#     - DynamoDBロックテーブル proxmox-ministack-tflock（LockID パーティションキー）
#   両方とも「既に存在すればスキップ」なので何度実行しても安全
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/ministack.sh"

TFSTATE_BUCKET="${TFSTATE_BUCKET:-proxmox-ministack-tfstate}"
TFLOCK_TABLE="${TFLOCK_TABLE:-proxmox-ministack-tflock}"

usage() {
    sed -n '2,12p' "${BASH_SOURCE[0]}"
    exit 1
}

ENV="${1:-}"
[[ "$ENV" == "ministack" || "$ENV" == "aws" ]] || usage

# aws を実行するサブシェル: ENV に応じて向き先を切り替える
run_aws() {
    if [[ "$ENV" == "ministack" ]]; then
        ms_aws "$@"
    else
        ms_aws_real "$@"
    fi
}

REGION="$( [[ "$ENV" == "ministack" ]] && ms_region || echo "${AWS_REGION:-ap-northeast-1}" )"

if [[ "$ENV" == "aws" ]]; then
    _ms_log "本物のAWS認証を確認しています ..."
    if ! ms_aws_real sts get-caller-identity >/dev/null 2>&1; then
        _ms_err "AWS 認証に失敗しました。aws sso login / 環境変数 / プロファイルを確認してください"
        exit 1
    fi
    _ms_log "認証OK: $(ms_aws_real sts get-caller-identity --query 'Arn' --output text)"
fi

# ---- S3バケット --------------------------------------------------------------
if run_aws s3api head-bucket --bucket "$TFSTATE_BUCKET" >/dev/null 2>&1; then
    _ms_log "S3バケットは既に存在します: $TFSTATE_BUCKET"
else
    _ms_log "S3バケットを作成します: $TFSTATE_BUCKET (region: $REGION)"
    if [[ "$ENV" == "aws" && "$REGION" != "us-east-1" ]]; then
        run_aws s3api create-bucket \
            --bucket "$TFSTATE_BUCKET" \
            --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION"
    else
        run_aws s3api create-bucket --bucket "$TFSTATE_BUCKET" --region "$REGION"
    fi
    # 本番運用ではバージョニング＋暗号化を有効にしておく（MiniStackでも動作する）
    run_aws s3api put-bucket-versioning --bucket "$TFSTATE_BUCKET" \
        --versioning-configuration Status=Enabled >/dev/null 2>&1 || true
    run_aws s3api put-bucket-encryption --bucket "$TFSTATE_BUCKET" \
        --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' \
        >/dev/null 2>&1 || true
    _ms_log "作成しました"
fi

# ---- DynamoDBロックテーブル ----------------------------------------------------
if run_aws dynamodb describe-table --table-name "$TFLOCK_TABLE" >/dev/null 2>&1; then
    _ms_log "DynamoDBロックテーブルは既に存在します: $TFLOCK_TABLE"
else
    _ms_log "DynamoDBロックテーブルを作成します: $TFLOCK_TABLE"
    run_aws dynamodb create-table \
        --table-name "$TFLOCK_TABLE" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "$REGION" >/dev/null
    _ms_log "作成しました（利用可能になるまで数十秒かかることがあります）"
fi

_ms_log "bootstrap 完了（${ENV}）。次: scripts/tf.sh ${ENV} init"
