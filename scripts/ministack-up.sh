#!/usr/bin/env bash
# =============================================================================
# ministack-up.sh — MiniStack を起動してヘルスチェックまで行う
#   使い方: scripts/ministack-up.sh [--timeout N]
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/ministack.sh"

TIMEOUT=60
if [[ "${1:-}" == "--timeout" ]]; then TIMEOUT="$2"; shift 2; fi

command -v docker >/dev/null 2>&1 || { _ms_err "docker が見つかりません"; exit 1; }
docker info >/dev/null 2>&1 || { _ms_err "Docker デーモンが動いていません"; exit 1; }

if [[ ! -f "$MS_ROOT/.env" ]]; then
    _ms_log ".env が無いため .env.example から作成します（環境に合わせて編集してください）"
    cp "$MS_ROOT/.env.example" "$MS_ROOT/.env"
fi
# .env 作成後に再度読み込み
ms_load_env

ms_write_blocked_hosts_override
if (( MS_BLOCKED_HOSTS_COUNT > 0 )); then
    _ms_log "実環境への誤送信を防ぐため ${MS_BLOCKED_HOSTS_COUNT} 件のホスト名を遮断します（MINISTACK_BLOCKED_HOSTS）"
else
    _ms_log "MINISTACK_BLOCKED_HOSTS は未設定です。実在する環境の構成を流し込む場合は、その環境のホスト名を設定してください（docs/02）"
fi

_ms_log "MiniStack を起動します (image: ministackorg/ministack:${MINISTACK_VERSION:-latest})"
docker compose --env-file "$MS_ROOT/.env" --project-directory "$MS_ROOT/compose" \
    -f "$MS_ROOT/compose/docker-compose.yml" -f "$MS_ROOT/compose/docker-compose.blocked-hosts.yml" up -d "$@"

_ms_log "ヘルスチェックを待っています (最大 ${TIMEOUT}s) ..."
if ms_ready "$TIMEOUT"; then
    _ms_log "起動完了: $(ms_endpoint)"
    _ms_log "  状態確認:   scripts/healthcheck.sh"
    _ms_log "  初回のみ:   scripts/bootstrap-backend.sh ministack   # tfstate用バケット作成"
else
    _ms_err "起動に失敗した可能性があります。ログを確認: docker logs ministack"
    exit 1
fi
