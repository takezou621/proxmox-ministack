#!/usr/bin/env bash
# =============================================================================
# lib/ministack.sh — MiniStack / AWS 二重環境コアライブラリ
#
# このファイルは実行するものではなく、source して使う（bash / zsh 両対応）:
#
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/ministack.sh"   # bash
#   source "$(cd "$(dirname ${(%):-%N})/.." && pwd)/lib/ministack.sh"            # zsh
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
# ms_use は切替前の AWS_* 環境変数を退避し、ms_clear はそれを復元する。
# そのため「環境変数で本番AWS認証を渡しているシェル」で ms_use -> ms_clear
# しても認証情報は失われない（CIや exported creds との併用が安全）。

# ms_use が上書きする対象（= ms_clear が復元する対象）
_MS_MANAGED_VARS=(
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
)
_MS_UNDEF="__ms_unset__"

# 変数の現在値をstdoutへ返す（未定義なら非0で終了）。
# bashの ${!name} / zshの ${(P)name} を使わず printenv で間接参照することで
# bash / zsh 両方から source できるようにしている
_ms_getvar() {
    printenv "$1"
}

# 現在設定されている AWS_ENDPOINT_URL_<SERVICE> 形式の変数名を列挙する
#（AWS CLI は AWS_ENDPOINT_URL よりサービス別変数を優先するため、
#  ms_use はこれらも MiniStack 向けに上書きする）
_ms_endpoint_var_names() {
    local line k
    while IFS= read -r line || [[ -n "$line" ]]; do
        k="${line%%=*}"
        case "$k" in AWS_ENDPOINT_URL_*) echo "$k" ;; esac
    done <<EOF
$(printenv)
EOF
}

# カレントシェル（または呼び出し元関数）を MiniStack 向けに切替。
# AWS CLI 2.13+/各種SDK は AWS_ENDPOINT_URL を尊重するため、--endpoint-url が不要になる
ms_use() {
    local v val
    # 既存値の退避は「初回の ms_use」のみ行う（連続 ms_use で元値を潰さない）。
    # マネージ対象のほか、外部から設定された任意のサービス別 endpoint 変数も退避する
    if [[ -z "${_MS_SAVED:-}" ]]; then
        for v in "${_MS_MANAGED_VARS[@]}"; do
            if val="$(_ms_getvar "$v")"; then
                export "_MS_PREV_${v}=${val}"
            else
                export "_MS_PREV_${v}=${_MS_UNDEF}"
            fi
        done
        _MS_EXTRA_VARS=""
        while IFS= read -r v; do
            [[ -z "$v" ]] && continue
            case " ${_MS_MANAGED_VARS[*]} " in *" $v "*) continue ;; esac
            if val="$(_ms_getvar "$v")"; then
                export "_MS_PREV_${v}=${val}"
                _MS_EXTRA_VARS="${_MS_EXTRA_VARS:+$_MS_EXTRA_VARS }$v"
            fi
        done <<EOF
$(_ms_endpoint_var_names)
EOF
        export _MS_SAVED=1
        export _MS_EXTRA_VARS="${_MS_EXTRA_VARS:-}"
    fi
    export AWS_ENDPOINT_URL="$(ms_endpoint)"
    # サービス別変数は AWS_ENDPOINT_URL より優先されるため全て MiniStack へ向ける
    while IFS= read -r v; do
        [[ -z "$v" ]] && continue
        export "$v=$(ms_endpoint)"
    done <<EOF
$(_ms_endpoint_var_names)
AWS_ENDPOINT_URL_S3
AWS_ENDPOINT_URL_DYNAMODB
AWS_ENDPOINT_URL_SQS
AWS_ENDPOINT_URL_RDS
EOF
    export AWS_ACCESS_KEY_ID="test"
    export AWS_SECRET_ACCESS_KEY="test"
    export AWS_DEFAULT_REGION="$(ms_region)"
    export AWS_REGION="$(ms_region)"
    export AWS_EC2_METADATA_DISABLED="true"   # 実メタデータサーバへの誤アクセス防止
    export AWS_PAGER=""
    export MS_CURRENT_MODE="ministack"
    _ms_log "MiniStack モードに切り替えました: ${AWS_ENDPOINT_URL} (region: ${AWS_DEFAULT_REGION})"
}

# 本物の AWS 向けに戻す。
# ms_use された形跡があれば当時の値（認証情報を含む）へ復元し、無ければ
# エンドポイント向きのみ解除して認証情報には触れない。
ms_clear() {
    local v ref val
    if [[ -n "${_MS_SAVED:-}" ]]; then
        for v in "${_MS_MANAGED_VARS[@]}" ${_MS_EXTRA_VARS:-}; do
            [[ -z "$v" ]] && continue
            ref="_MS_PREV_${v}"
            if val="$(_ms_getvar "$ref")"; then
                if [[ "$val" == "$_MS_UNDEF" ]]; then
                    unset "$v" 2>/dev/null || true
                else
                    export "$v=$val"
                fi
            fi
            unset "$ref" 2>/dev/null || true
        done
        unset _MS_SAVED _MS_EXTRA_VARS 2>/dev/null || true
    else
        unset AWS_ENDPOINT_URL AWS_ENDPOINT_URL_S3 AWS_ENDPOINT_URL_DYNAMODB \
            AWS_ENDPOINT_URL_SQS AWS_ENDPOINT_URL_RDS 2>/dev/null || true
    fi
    export MS_CURRENT_MODE="aws"
    _ms_log "AWS モードに切り替えました（ms_use 前の認証・設定へ復元）"
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
    printf '本当に実行しますか? yes と入力: ' >&2
    local ans
    read -r ans
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
            # 削除失敗（権限不足等）でループが止まらないよう、失敗時は明示的に終了する
            if ! ms_aws s3api delete-objects --bucket "$bucket" --delete "file://$tmp" >/dev/null 2>&1; then
                _ms_err "オブジェクトの削除に失敗しました: s3://$bucket （権限等を確認してください）"
                rm -f "$tmp"
                return 1
            fi
        done
        rm -f "$tmp"
    fi
    # jq 無し環境向けフォールバック（現行バージョンのみ）
    ms_aws s3 rm "s3://$bucket/" --recursive >/dev/null 2>&1 || true
    _ms_log "バケットを空にしました: s3://$bucket"
}

# ms_write_blocked_hosts_override — MINISTACK_BLOCKED_HOSTS から compose の上書きファイルを生成する
#   MiniStack は SNS の HTTPS 購読確認・EventBridge の API destination・API Gateway の HTTP 統合を、
#   設定された URL へ「実際に」送信する。実在する環境の構成を流し込むと、その環境へ誤送信してしまうため、
#   指定したホスト名を MiniStack コンテナ内で 127.0.0.1 に解決させて接続を拒否させる（extra_hosts）。
#   ホスト名は .env（コミットしない）で指定する: MINISTACK_BLOCKED_HOSTS="api.example.com,api-stg.example.com"
#   生成物: compose/docker-compose.blocked-hosts.yml（.gitignore 対象。未指定なら空の上書き）
ms_write_blocked_hosts_override() {
    local out="$MS_ROOT/compose/docker-compose.blocked-hosts.yml"
    local raw="${MINISTACK_BLOCKED_HOSTS:-}" h n=0
    {
        echo "# scripts/ministack-up.sh が .env の MINISTACK_BLOCKED_HOSTS から自動生成する。編集しない（.gitignore 対象）"
        if [[ -z "${raw//[[:space:],]/}" ]]; then
            echo "services: {}"
        else
            echo "services:"
            echo "  ministack:"
            echo "    extra_hosts:"
            for h in ${raw//,/ }; do
                # YAML への混入を避けるため、ホスト名として妥当な文字だけを許す
                [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] || { _ms_err "MINISTACK_BLOCKED_HOSTS に不正なホスト名があります: $h"; return 1; }
                echo "      - \"$h:127.0.0.1\""
                n=$((n + 1))
            done
        fi
    } > "$out"
    MS_BLOCKED_HOSTS_COUNT=$n
}
