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

    # RDS_PERSIST=1 で作られた RDS のデータボリュームも削除する
    # （compose 管理外の Docker 名前付きボリューム。命名は MiniStack の
    #   ministack/services/rds.py の規約: ministack-rds-*-data）
    RDS_VOLUMES="$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep '^ministack-rds-' || true)"
    if [[ -n "$RDS_VOLUMES" ]]; then
        _ms_warn "RDSのデータボリュームが見つかりました（DBのデータが消えます）:"
        printf '%s\n' "$RDS_VOLUMES" | sed 's/^/    /' >&2
        read -r -p "これらのボリュームも削除しますか? yes と入力: " ans2
        if [[ "$ans2" == "yes" ]]; then
            printf '%s\n' "$RDS_VOLUMES" | xargs docker volume rm >/dev/null 2>&1 || {
                _ms_warn "一部のボリュームが削除できませんでした（コンテナが掴んでいる可能性）。以下で確認してください: docker volume ls | grep ministack-rds"
            }
            _ms_log "RDSボリュームを削除しました"
        else
            _ms_log "RDSボリュームは残しています"
        fi
    fi
fi

# RDS/ElastiCache の「本物のコンテナ」は compose 管理外なので掃除する
LEFT=$(docker ps -a --filter "label=ministack" --format '{{.Names}}' 2>/dev/null || true)
if [[ -n "$LEFT" ]]; then
    _ms_log "MiniStack が起動していたDBコンテナを掃除します: $(echo "$LEFT" | tr '\n' ' ')"
    echo "$LEFT" | xargs -r docker rm -f >/dev/null 2>&1 || true
fi
_ms_log "停止しました"
