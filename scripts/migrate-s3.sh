#!/usr/bin/env bash
# =============================================================================
# migrate-s3.sh — MiniStack と AWS の間で S3 の中身（実データ）を同期する
#
#   使い方:
#     scripts/migrate-s3.sh --list                          # コピー元のバケット一覧
#     scripts/migrate-s3.sh                                 # 全バケットを MiniStack→AWS へ
#     scripts/migrate-s3.sh --bucket my-bucket --prefix assets/
#     scripts/migrate-s3.sh --bucket src1,src2:rename-dst   # 複数指定＋名前変更（src:dst）
#     scripts/migrate-s3.sh --map my-app-ministack-artifacts:my-app-prod-artifacts
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
#
#   バケット名対応付け:
#     コピー元とコピー先でバケット名が違う場合（例: *-ministack-artifacts →
#     *-prod-artifacts）は --bucket に "src:dst" 形式を使うか、--map を指定する。
#     指定しないバケットは同名のまま同期される。
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/ministack.sh"

FROM="ministack"
TO="aws"
# エントリは "src:dst" 形式で保持する（同名の場合は "name:name" に正規化）。
# S3バケット名にコロンは含まれないため区切りとして安全。bash 3.2 でも動くよう
# 連想配列は使わない
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

# "a,b" や "a:b" のカンマ区切りを "src:dst" 形式の改行区切りに正規化する
normalize_entries() {
    local raw="$1" item
    printf '%s\n' "$raw" | tr ',' '\n' | while IFS= read -r item; do
        item="${item//[[:space:]]/}"
        [[ -z "$item" ]] && continue
        case "$item" in
            *:*) printf '%s\n' "$item" ;;
            *)   printf '%s:%s\n' "$item" "$item" ;;
        esac
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)         FROM="$2"; shift 2 ;;
        --to)           TO="$2"; shift 2 ;;
        --bucket)       BUCKETS="${BUCKETS:+$BUCKETS$'\n'}$(normalize_entries "$2")"; shift 2 ;;
        --map)          BUCKETS="${BUCKETS:+$BUCKETS$'\n'}$(normalize_entries "$2")"; shift 2 ;;
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
    _MS_LISTED="$(aws_src s3api list-buckets --query 'Buckets[].Name' --output text | tr '\t' '\n' | grep -v '^proxmox-ministack-tfstate$' || true)"
    if [[ -z "$_MS_LISTED" ]]; then
        _ms_log "コピーできるバケットがありません"
        exit 0
    fi
    BUCKETS="$(printf '%s\n' "$_MS_LISTED" | while IFS= read -r b; do printf '%s:%s\n' "$b" "$b"; done)"
fi

if (( LIST )); then
    printf '%s\n' "$BUCKETS" | cut -d: -f1
    exit 0
fi

_ms_log "同期: $SRC_LABEL -> $DST_LABEL"
_ms_log "バケット: $(printf '%s\n' "$BUCKETS" | tr '\n' ' ')"
[[ -n "$PREFIX" ]] && _ms_log "prefix: $PREFIX"
(( DRYRUN )) && _ms_warn "dry-run モード（実際には書き込みません）"
(( DELETE )) && _ms_warn "--delete 有効: コピー元に無いオブジェクトはコピー先からも削除されます"

if [[ "$TO" == "aws" && -z "$TO_ENDPOINT" ]]; then
    aws_dst sts get-caller-identity >/dev/null 2>&1 || {
        _ms_err "本物のAWS認証がありません"; exit 1; }
fi

# ---- 2段階sync ----------------------------------------------------------------
# 取得側（source -> stage）は常に --delete で「ソースの完全ミラー」を作る。
# これを怠ると過去の同期で stage に残った古いファイルが、コピー元で削除済みでも
# 書き戻し時に復活してしまうため。
# 書き戻し側（stage -> dest）の --delete は利用者が明示的に指定する（非破壊デフォルト）。
PULL_FLAGS=(--delete)
PUSH_FLAGS=()
# aws s3 系のドライランは --dryrun（ハイフンなし）。スクリプト自体のオプションは --dry-run
(( DRYRUN )) && { PULL_FLAGS+=(--dryrun); PUSH_FLAGS+=(--dryrun); }
(( DELETE )) && PUSH_FLAGS+=(--delete)

TOTAL_O=0
for ENTRY in $BUCKETS; do
    # エントリは "src:dst" 形式（normalize_entries で正規化済み）
    SRC_B="${ENTRY%%:*}"
    DST_B="${ENTRY##*:}"
    echo
    if [[ "$SRC_B" == "$DST_B" ]]; then
        _ms_log "== バケット: $SRC_B =="
    else
        _ms_log "== バケット: ${SRC_B} -> ${DST_B}（名前変更あり） =="
    fi

    if ! aws_src s3api head-bucket --bucket "$SRC_B" >/dev/null 2>&1; then
        _ms_warn "コピー元に存在しません、スキップします: $SRC_B"
        continue
    fi

    # コピー先にバケットが無い場合:
    #   通常   -> 作成する
    #   dry-run -> 作成もスキップする（dry-run はコピー先に一切変更を加えない）
    if aws_dst s3api head-bucket --bucket "$DST_B" >/dev/null 2>&1; then
        :
    elif (( DRYRUN )); then
        _ms_warn "dry-run: コピー先にバケットが無いためこのバケットの同期をスキップします（実行時は作成されます）: $DST_B"
        continue
    elif [[ "$TO" == "aws" && -z "$TO_ENDPOINT" ]]; then
        REGION="${AWS_REGION:-ap-northeast-1}"
        _ms_log "コピー先にバケットが無いため作成します: $DST_B (region: $REGION)"
        if [[ "$REGION" == "us-east-1" ]]; then
            aws_dst s3api create-bucket --bucket "$DST_B" --region "$REGION"
        else
            aws_dst s3api create-bucket --bucket "$DST_B" --region "$REGION" \
                --create-bucket-configuration LocationConstraint="$REGION"
        fi
    else
        _ms_log "コピー先にバケットが無いため作成します: $DST_B"
        aws_dst s3api create-bucket --bucket "$DST_B" --region "$(ms_region)"
    fi

    STAGE="$WORKDIR/$SRC_B"
    mkdir -p "$STAGE"

    _ms_log "  1/2 取得: s3://$SRC_B/$PREFIX -> $STAGE"
    aws_src s3 sync "s3://$SRC_B/${PREFIX}" "$STAGE/" ${PULL_FLAGS[@]+"${PULL_FLAGS[@]}"}

    _ms_log "  2/2 書き戻し: $STAGE/ -> s3://$DST_B/${PREFIX} ($DST_LABEL)"
    aws_dst s3 sync "$STAGE/" "s3://$DST_B/${PREFIX}" ${PUSH_FLAGS[@]+"${PUSH_FLAGS[@]}"}

    N=$(find "$STAGE" -type f | wc -l | tr -d ' ')
    _ms_log "  完了: ${N} ファイル"
    TOTAL_O=$((TOTAL_O + N))
done

echo
_ms_log "同期完了: バケット $(printf '%s\n' "$BUCKETS" | wc -l | tr -d ' ')件 / ファイル ${TOTAL_O}件"
if (( DRYRUN )); then
    _ms_log "dry-run のため何も書き込んでいません。実行するには --dry-run を外してください"
fi
