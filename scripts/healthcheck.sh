#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh — MiniStack の状態を表示する
#   使い方: scripts/healthcheck.sh
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/ministack.sh"

if ! ms_ready 5; then
    exit 1
fi

_ms_log "OK: $(ms_endpoint)"

# 起動しているDB系コンテナ（RDS/ElastiCache の兄弟コンテナ）があれば表示
DBS=$(docker ps --filter "name=ministack-" --format 'table {{.Names}}\t{{.Ports}}\t{{.Status}}' 2>/dev/null \
      | grep -v -E '^ministack(\s|$)|^ministack-redis\s' || true)
if [[ -n "$DBS" ]]; then
    echo
    _ms_log "稼働中のDB/キャッシュコンテナ:"
    echo "$DBS"
fi

echo
ms_health
