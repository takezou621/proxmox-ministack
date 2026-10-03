#!/usr/bin/env bash
# =============================================================================
# migrate-s3.sh — MiniStack と AWS の間で S3 の中身（実データ）を同期する
#
#   使い方:
#     scripts/migrate-s3.sh --list                          # コピー元のバケット一覧
#     scripts/migrate-s3.sh                                 # 全バケットを MiniStack→AWS へ
#     scripts/migrate-s3.sh --bucket my-bucket --prefix assets/
#     scripts/migrate-s3.sh --dry-run                       # 何をするかだけ表示
#     scripts/migrate-s3.sh --from aws --to ministack       # 逆方向（AWS→MiniStack＝切り戻し）
#
#   仕組み:
#     aws s3 sync は1コマンドで2つの異なるエンドポイントをまたげないため、
#     一度ローカルの作業ディレクトリに落としてから同期先へ書き戻す（2段階sync）。
#     sync なので差分のみ転送される（再実行OK）。大量データは docs/04 の rclone 推奨。
#
#   注意: バケットの「中身」だけを移動する。バケット自体は Terraform
#         （scripts/tf.sh aws apply）で先に作られている前提。
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/ministack.sh"

FROM="ministack"
TO="aws"
BUCKETS=""
PREFIX=""
WORKDIR="${WORKDIR:-${TMPDIR:-/tmp}}"
WORKDIR="${WORKDIR%/}/ms-s3-migrate"
DRYRUN=0
DELETE=0
LIST=0
FROM_ENDPOINT=""
TO_ENDPOINT=""

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)         FROM="$2"; shift 2 ;;
        --to)           TO="$2"; shift 2 ;;
        --bucket)       BUCKETS="$2"; shift 2 ;;
        --prefix)       PREFIX="${2%/}/"; shift 2 ;;
        --workdir)      WORKDIR="$2"; shift 2 ;;
        --dry-run)      DRYRUN=1; shift ;;
        --delete)       DELETE=1; shift ;;
        --list)         LIST=1; shift ;;
        --from-endpoint) FROM_ENDPOINT="$2"; shift 2 ;;
        --to-endpoint)   TO_ENDPOINT="$2"; shift 2 ;;
        -h|--help)      usage ;;
        *) _ms_err "不明な引数: $1"; usage ;;
    esac
done

[[ "$FROM" == "ministack" || "$FROM" == "aws" ]] || { _ms_err "--from は ministack か aws"; exit 1; }
[[ "$TO" == "ministack" || "$TO" == "aws" ]] || { _ms_err "--to は ministack か aws"; exit 1; }
[[ "$FROM" != "$TO" || -n "$FROM_ENDPOINT$TO_ENDPOINT" ]] || { _ms_err "--from と --to が同じです"; exit 1; }

# ---- 向き先ごとの aws コマンドラッパ（サブシェルで環境を分離） ----------------
# ENDPOINT指定時は任意のエンドポイントへ（テスト/バックアップ用のescape hatch）
aws_src() {
    (
        if [[ -n "$FROM_ENDPOINT" ]]; then
            export AWS_ENDPOINT_URL="$FROM_ENDPOINT" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$(ms_region)" AWS_EC2_METADATA_DISABLED=true
        elif [[ "$FROM" == "ministack" ]]; then
            ms_use
        else
            ms_clear
        fi
        exec aws "$@"
    )
}
aws_dst() {
    (
        if [[ -n "$TO_ENDPOINT" ]]; then
            export AWS_ENDPOINT_URL="$TO_ENDPOINT" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$(ms_region)" AWS_EC2_METADATA_DISABLED=true
        elif [[ "$TO" == "ministack" ]]; then
            ms_use
        else
            ms_clear
        fi
        exec aws "$@"
    )
}

SRC_LABEL="$FROM${FROM_ENDPOINT:+ ($FROM_ENDPOINT)}"
DST_LABEL="$TO${TO_ENDPOINT:+ ($TO_ENDPOINT)}"

# ---- バケット一覧 -------------------------------------------------------------
if [[ -z "$BUCKETS" ]]; then
    _ms_log "コピー元（${SRC_LABEL}）のバケット一覧を取得します"
    # tfstate用バケットはインフラ管理対象なのでデータ同期から除外
    BUCKETS="$(aws_src s3api list-buckets --query 'Buckets[].Name' --output text | tr '\t' '\n' | grep -v '^proxmox-ministack-tfstate$' || true)"
    if [[ -z "$BUCKETS" ]]; then
        _ms_log "コピーできるバケットがありません"
        exit 0
    fi
fi

if (( LIST )); then
    echo "$BUCKETS"
    exit 0
fi

_ms_log "同期: $SRC_LABEL -> $DST_LABEL"
_ms_log "バケット: $(echo "$BUCKETS" | tr '\n' ' ')"
[[ -n "$PREFIX" ]] && _ms_log "prefix: $PREFIX"
(( DRYRUN )) && _ms_warn "dry-run モード（実際には書き込みません）"
(( DELETE )) && _ms_warn "--delete 有効: コピー元に無いオブジェクトはコピー先からも削除されます"

if [[ "$TO" == "aws" && -z "$TO_ENDPOINT" ]]; then
    aws_dst sts get-caller-identity >/dev/null 2>&1 || {
        _ms_err "本物のAWS認証がありません"; exit 1; }
fi

# ---- 2段階sync ----------------------------------------------------------------
SYNC_FLAGS=()
(( DRYRUN )) && SYNC_FLAGS+=(--dry-run)
(( DELETE )) && SYNC_FLAGS+=(--delete)

TOTAL_O=0
for B in $BUCKETS; do
    echo
    _ms_log "== バケット: $B =="

    if ! aws_src s3api head-bucket --bucket "$B" >/dev/null 2>&1; then
        _ms_warn "コピー元に存在しません、スキップします: $B"
        continue
    fi

    # コピー先にバケットが無ければ作る（tfstateバケットは除く）
    if ! aws_dst s3api head-bucket --bucket "$B" >/dev/null 2>&1; then
        if [[ "$TO" == "aws" && -z "$TO_ENDPOINT" ]]; then
            REGION="${AWS_REGION:-ap-northeast-1}"
            _ms_log "コピー先にバケットが無いため作成します: $B (region: $REGION)"
            if [[ "$REGION" == "us-east-1" ]]; then
                aws_dst s3api create-bucket --bucket "$B" --region "$REGION"
            else
                aws_dst s3api create-bucket --bucket "$B" --region "$REGION" \
                    --create-bucket-configuration LocationConstraint="$REGION"
            fi
        else
            _ms_log "コピー先にバケットが無いため作成します: $B"
            aws_dst s3api create-bucket --bucket "$B" --region "$(ms_region)"
        fi
    fi

    STAGE="$WORKDIR/$B"
    mkdir -p "$STAGE"

    _ms_log "  1/2 取得: s3://$B/$PREFIX -> $STAGE"
    aws_src s3 sync "s3://$B/${PREFIX}" "$STAGE/" ${SYNC_FLAGS[@]+"${SYNC_FLAGS[@]}"}

    _ms_log "  2/2 書き戻し: $STAGE/ -> s3://$B/${PREFIX} ($DST_LABEL)"
    aws_dst s3 sync "$STAGE/" "s3://$B/${PREFIX}" ${SYNC_FLAGS[@]+"${SYNC_FLAGS[@]}"}

    N=$(find "$STAGE" -type f | wc -l | tr -d ' ')
    _ms_log "  完了: ${N} ファイル"
    TOTAL_O=$((TOTAL_O + N))
done

echo
_ms_log "同期完了: バケット $(echo "$BUCKETS" | wc -l | tr -d ' ')件 / ファイル ${TOTAL_O}件"
if (( DRYRUN )); then
    _ms_log "dry-run のため何も書き込んでいません。実行するには --dry-run を外してください"
fi
