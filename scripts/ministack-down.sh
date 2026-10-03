#!/usr/bin/env bash
# =============================================================================
# ministack-down.sh — MiniStack を停止する
#   使い方: scripts/ministack-down.sh [--reset-data]
#     --reset-data  data/ （S3オブジェクト・状態・Redis）も削除する（破壊的）
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/ministack.sh"

RESET_DATA=0
if [[ "${1:-}" == "--reset-data" ]]; then RESET_DATA=1; fi

_ms_log "MiniStack を停止します"
docker compose --env-file "$MS_ROOT/.env" --project-directory "$MS_ROOT/compose" down

if (( RESET_DATA )); then
    _ms_warn "compose/data を削除します（S3オブジェクト・状態・Redisデータが消えます）"
    read -r -p "本当に削除しますか? yes と入力: " ans
    [[ "$ans" == "yes" ]] || { _ms_log "中断しました"; exit 1; }
    rm -rf "$MS_ROOT/compose/data"
    _ms_log "データを削除しました"
fi

# RDS/ElastiCache の「本物のコンテナ」は compose 管理外なので掃除する
LEFT=$(docker ps -a --filter "label=ministack" --format '{{.Names}}' 2>/dev/null || true)
if [[ -n "$LEFT" ]]; then
    _ms_log "MiniStack が起動していたDBコンテナを掃除します: $(echo "$LEFT" | tr '\n' ' ')"
    echo "$LEFT" | xargs -r docker rm -f >/dev/null 2>&1 || true
fi
_ms_log "停止しました"
