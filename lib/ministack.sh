#!/usr/bin/env bash
# =============================================================================
# lib/ministack.sh — MiniStack / AWS 二重環境コアライブラリ
#
# このファイルは実行するものではなく、source して使う:
#
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/ministack.sh"
#
# 主なAPI:
#   ms_endpoint            MiniStack のエンドポイントURLを表示 (http://HOST:PORT)
#   ms_use                 カレントシェルを「MiniStack向け」に切替（AWS_ENDPOINT_URL等をexport）
#   ms_clear               カレントシェルを「本物のAWS向け」に戻す（envを解除）
#   ms_aws <args...>       MiniStack に向けて aws コマンドを実行
#   ms_aws_real <args...>  本物の AWS に向けて aws コマンドを実行
#   ms_ready [timeout]     MiniStack の起動/到達可能性チェック（戻り値 0/1）
#   ms_health              ヘルス情報（/_ministack/health）を整形して表示
#   ms_reset               MiniStack の全状態をリセット（危険操作・要確認）
#
# 設定はリポジトリ直下の .env（無ければ .env.example）から読み込む。
# 既にシェルに設定済みの値は .env より優先される。
# =============================================================================

[[ -n "${_MS_LIB_SOURCED:-}" ]] && return 0
_MS_LIB_SOURCED=1

# ---- リポジトリルート（このファイルの親の親） -------------------------------
MS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- .env の読み込み ---------------------------------------------------------
# 「環境変数に既に値があれば上書きしない」方針（CIや一時上書きを可能にするため）
ms_load_env() {
    local f="${1:-}"
    if [[ -z "$f" ]]; then
        f="$MS_ROOT/.env"
        [[ -r "$f" ]] || f="$MS_ROOT/.env.example"
    fi
    [[ -r "$f" ]] || return 0

    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        # 空行とコメントはスキップ
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" == \#* ]] && continue
        [[ "$line" != *=* ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        key="${key//[[:space:]]/}"
        [[ -z "$key" ]] && continue
        # シェル引用符を外す（"..." と '...' のみ。複雑な値は環境変数で渡すこと）
        if [[ "$val" == \"*\" && "$val" == *\" ]]; then
            val="${val#\"}"; val="${val%\"}"
        elif [[ "$val" == \'*\' && "$val" == *\' ]]; then
            val="${val#\'}"; val="${val%\'}"
        fi
        [[ -n "${!key:-}" ]] && continue
        export "$key=$val"
    done < "$f"
}
ms_load_env

# ---- 基本値 ------------------------------------------------------------------
ms_host()   { echo "${MINISTACK_HOST:-localhost}"; }
ms_port()   { echo "${MINISTACK_PORT:-4566}"; }
ms_region() { echo "${MINISTACK_REGION:-ap-northeast-1}"; }
ms_endpoint() { echo "http://$(ms_host):$(ms_port)"; }

# ms_service_url <service> — サービス別URL（MiniStackは全サービス同一ポート）
ms_service_url() { ms_endpoint; }

# ---- ログ出力（コマンド置換でデータに混ざらないよう、すべてstderrへ） ---------
_ms_log()  { printf '\033[1;34m[ms]\033[0m %s\n' "$*" >&2; }
_ms_warn() { printf '\033[1;33m[ms:warn]\033[0m %s\n' "$*" >&2; }
_ms_err()  { printf '\033[1;31m[ms:error]\033[0m %s\n' "$*" >&2; }

# ---- MiniStack / AWS 切り替え -------------------------------------------------
# MiniStack が export する AWS 系環境変数の一覧（ms_clear でも使う）
_MS_EXPORTED_VARS=(
    AWS_ENDPOINT_URL
    AWS_ENDPOINT_URL_S3
    AWS_ENDPOINT_URL_DYNAMODB
    AWS_ENDPOINT_URL_SQS
    AWS_ENDPOINT_URL_RDS
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    AWS_SESSION_TOKEN
    AWS_DEFAULT_REGION
    AWS_REGION
    AWS_EC2_METADATA_DISABLED
    AWS_PAGER
    AWS_RETRY_MODE
    MS_CURRENT_MODE
)

# カレントシェル（または呼び出し元関数）を MiniStack 向けに切替。
# AWS CLI 2.13+/各種SDK は AWS_ENDPOINT_URL を尊重するため、--endpoint-url が不要になる
ms_use() {
    export AWS_ENDPOINT_URL="$(ms_endpoint)"
    export AWS_ACCESS_KEY_ID="test"
    export AWS_SECRET_ACCESS_KEY="test"
    export AWS_DEFAULT_REGION="$(ms_region)"
    export AWS_REGION="$(ms_region)"
    export AWS_EC2_METADATA_DISABLED="true"   # 実メタデータサーバへの誤アクセス防止
    export AWS_PAGER=""
    export MS_CURRENT_MODE="ministack"
    _ms_log "MiniStack モードに切り替えました: ${AWS_ENDPOINT_URL} (region: ${AWS_DEFAULT_REGION})"
}

# 本物の AWS 向けに戻す（認証は標準チェーン: 環境変数/SSO/~/.aws/credentials）
ms_clear() {
    local v
    for v in "${_MS_EXPORTED_VARS[@]}"; do
        unset "$v" 2>/dev/null || true
    done
    export MS_CURRENT_MODE="aws"
    _ms_log "AWS モードに切り替えました（標準の認証チェーンを使用）"
}

# 1コマンドだけMiniStack向けの aws を実行（サブシェルなので現在のシェルは汚さない）
ms_aws() {
    (
        ms_use
        exec aws "$@"
    )
}

# 1コマンドだけ本物のAWS向けの aws を実行
ms_aws_real() {
    (
        ms_clear
        exec aws "$@"
    )
}

# ---- ヘルスチェック ------------------------------------------------------------
# ms_ready [timeout_sec] — 起動していれば 0、そうでなければ 1
ms_ready() {
    local timeout="${1:-30}"
    local url="$(ms_endpoint)/_ministack/health"
    local waited=0 interval=2
    while (( waited < timeout )); do
        if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$interval"
        waited=$((waited + interval))
    done
    _ms_err "MiniStack が ${timeout} 秒以内に応答しません: $url"
    _ms_err ".env の MINISTACK_HOST / MINISTACK_PORT を確認するか、scripts/ministack-up.sh で起動してください"
    return 1
}

# ms_health — ヘルスJSONを見やすく表示
ms_health() {
    local url="$(ms_endpoint)/_ministack/health"
    local body
    body="$(curl -fsS --max-time 5 "$url")" || {
        _ms_err "ヘルスチェックに失敗: $url"
        return 1
    }
    if command -v jq >/dev/null 2>&1; then
        echo "$body" | jq .
    else
        echo "$body"
    fi
}

# ms_reset — POST /_ministack/reset で全サービスの状態を消す（S3オブジェクト含む）
# ※ ./data のディスク永続分は消えない場合がある。完全な初期化は down -> data削除 -> up
ms_reset() {
    local url="$(ms_endpoint)/_ministack/reset"
    _ms_warn "MiniStack の全状態（S3オブジェクト・DBインスタンス定義等）を消去します"
    read -r -p "本当に実行しますか? yes と入力: " ans
    [[ "$ans" == "yes" ]] || { _ms_log "中断しました"; return 1; }
    curl -fsS -X POST "$url" && echo
    _ms_log "リセット完了"
}

# ms_s3_purge <bucket> — バケットの中身を完全に空にする。
# バージョニング有効なバケットは `aws s3 rm` では空にならない
# （削除マーカーが残る）ため、全バージョン＋削除マーカーを消す。
# terraform destroy の前のお掃除用（バケット自体は残す）。
ms_s3_purge() {
    local bucket="$1"
    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp="$(mktemp)"
        while :; do
            ms_aws s3api list-object-versions --bucket "$bucket" --output json 2>/dev/null \
                | jq -c '{Objects: [(.Versions // [])[], (.DeleteMarkers // [])[]] | map({Key, VersionId})}' > "$tmp" || break
            [[ "$(jq '.Objects | length' "$tmp")" -eq 0 ]] && break
            ms_aws s3api delete-objects --bucket "$bucket" --delete "file://$tmp" >/dev/null 2>&1 || true
        done
        rm -f "$tmp"
    fi
    # jq 無し環境向けフォールバック（現行バージョンのみ）
    ms_aws s3 rm "s3://$bucket/" --recursive >/dev/null 2>&1 || true
    _ms_log "バケットを空にしました: s3://$bucket"
}
