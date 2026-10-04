#!/usr/bin/env bash
# =============================================================================
# migrate-rds.sh — MiniStack の RDS（実体はPostgreSQL/MySQLコンテナ）と
#                  本番AWSのRDSの間でダンプ＆リストアする
#
#   使い方:
#     # 1) MiniStack内のDBインスタンスとエンドポイントを確認
#     scripts/migrate-rds.sh --list
#
#     # 2) ダンプのみ取得
#     scripts/migrate-rds.sh --db mydb --password-env MYDB_PW --out mydb.sql
#
#     # 3) 本番AWSのRDSへリストア（--to-identifier でエンドポイント自動解決）
#     scripts/migrate-rds.sh --db mydb --password-env MYDB_PW \
#         --to-identifier mydb-prod --to-user admin --to-password-env PROD_PW --yes
#
#     # 4) 切り戻し（AWS→MiniStack）: --from aws でダンプしローカルへリストア
#     scripts/migrate-rds.sh --from aws --db mydb-prod --password-env PROD_PW \
#         --to-host <ProxmoxIP> --to-port 15432 --to-dbname appdb --yes
#
#   前提:
#     * postgres をダンプするなら pg_dump / psql、mysql なら mysqldump / mysql
#       がインストールされていること（macOS: brew install postgresql@16 mysql-client）
#     * MiniStack 側のマスターパスワードは CreateDBInstance 時に指定したもの
#     * 本番側は scripts/tf.sh aws apply で DBインスタンスが作成済みであること
#       （Terraformは「構造」を作る。中身のデータはこのスクリプトの仕事）
#
#   注意: --to-host を指定しない場合、--to-identifier から本番AWSの
#         describe-db-instances でエンドポイントを解決します。
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/ministack.sh"

DB_ID=""
FROM="ministack"
OUT=""
DUMP_PW_ENV=""
TO_IDENTIFIER=""
TO_HOST=""
TO_PORT=""
TO_USER=""
TO_DBNAME=""
TO_PW_ENV=""
YES=0
LIST=0
HOST_OVERRIDE=""

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)               LIST=1; shift ;;
        --from)               FROM="$2"; shift 2 ;;
        --db)                 DB_ID="$2"; shift 2 ;;
        --out)                OUT="$2"; shift 2 ;;
        --password-env)       DUMP_PW_ENV="$2"; shift 2 ;;
        --to-identifier)      TO_IDENTIFIER="$2"; shift 2 ;;
        --to-host)            TO_HOST="$2"; shift 2 ;;
        --to-port)            TO_PORT="$2"; shift 2 ;;
        --to-user)            TO_USER="$2"; shift 2 ;;
        --to-dbname)          TO_DBNAME="$2"; shift 2 ;;
        --to-password-env)    TO_PW_ENV="$2"; shift 2 ;;
        --host-override)      HOST_OVERRIDE="$2"; shift 2 ;;
        --yes|-y)             YES=1; shift ;;
        -h|--help)            usage ;;
        *) _ms_err "不明な引数: $1"; usage ;;
    esac
done

# ---- コピー元: インスタンス情報の取得 ------------------------------------------
# --from ministack（デフォルト）: MiniStack の RDS（実体はDBコンテナ）
# --from aws: 本番AWSの RDS（切り戻し用）
# 出力: ENGINE HOST PORT USER DBNAME (スペース区切り)
fetch_src_instance() {
    local inst
    if [[ "$FROM" == "aws" ]]; then
        inst="$(ms_aws_real rds describe-db-instances --db-instance-identifier "$DB_ID" \
            --query 'DBInstances[0].[Engine,Endpoint.Address,Endpoint.Port,MasterUsername,DBName]' \
            --output text 2>/dev/null)" || {
            _ms_err "本番AWS上にDBインスタンスが見つかりません: $DB_ID"; exit 1; }
    else
        inst="$(ms_aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
            --query 'DBInstances[0].[Engine,Endpoint.Address,Endpoint.Port,MasterUsername,DBName]' \
            --output text 2>/dev/null)" || {
            _ms_err "MiniStack 上にDBインスタンスが見つかりません: $DB_ID"; exit 1; }
        # RDS_PUBLIC_ENDPOINT 未設定だとコンテナ内部アドレスが返るので上書きできるようにする
        if [[ -n "$HOST_OVERRIDE" ]]; then
            HOST="$HOST_OVERRIDE"
        fi
    fi
    read -r ENGINE HOST PORT USER DBNAME <<< "$inst"
    if [[ -n "$HOST_OVERRIDE" ]]; then
        HOST="$HOST_OVERRIDE"
    fi
}

# ---- 一覧モード ----------------------------------------------------------------
if (( LIST )); then
    _ms_log "MiniStack 上のDBインスタンス一覧:"
    ms_aws rds describe-db-instances \
        --query 'DBInstances[].{ID:DBInstanceIdentifier,Engine:Engine,Status:DBInstanceStatus,Host:Endpoint.Address,Port:Endpoint.Port,User:MasterUsername}' \
        --output table
    exit 0
fi

[[ -n "$DB_ID" ]] || { _ms_err "--db が必須です（--list で一覧を確認できます）"; usage; }
fetch_src_instance

_ms_log "コピー元: $DB_ID ($ENGINE) $HOST:$PORT user=$USER db=${DBNAME:--}"

# ---- ダンプ --------------------------------------------------------------------
# ダンプにはDBの中身（機密）が平文で入るため、所有者のみ読み取り可能な権限で作る
umask 077

if [[ -z "$OUT" ]]; then
    OUT="${DB_ID}-$(date +%Y%m%d%H%M%S).sql"
fi

if [[ ! -f "$OUT" ]]; then
    if [[ -z "$DUMP_PW_ENV" || -z "${!DUMP_PW_ENV:-}" ]]; then
        _ms_err "ダンプにはマスターパスワードが必要です: --password-env <変数名> で指定"
        _ms_err "例: export ${DUMP_PW_ENV:-DB_PASSWORD}='...'; scripts/migrate-rds.sh --password-env ${DUMP_PW_ENV:-DB_PASSWORD} ..."
        exit 1
    fi

    case "$ENGINE" in
        postgres*)
            command -v pg_dump >/dev/null 2>&1 || { _ms_err "pg_dump がありません（brew install postgresql@16 など）"; exit 1; }
            _ms_log "pg_dump -> $OUT"
            PGPASSWORD="${!DUMP_PW_ENV}" pg_dump \
                -h "$HOST" -p "$PORT" -U "$USER" -d "${DBNAME:-postgres}" \
                --no-owner --no-privileges -f "$OUT"
            ;;
        mysql*)
            command -v mysqldump >/dev/null 2>&1 || { _ms_err "mysqldump がありません（brew install mysql-client など）"; exit 1; }
            if [[ -z "$DBNAME" || "$DBNAME" == "NULL" ]]; then
                _ms_err "MySQLのダンプにはデータベース名が必要です（describe-db-instances の DBName が空です）"
                _ms_err "CreateDBInstance 時に --db-name を指定したインスタンスを使うか、dump後に手動調整してください"
                exit 1
            fi
            _ms_log "mysqldump -> $OUT"
            # --databases を使わない（CREATE DATABASE/USE がdumpに入ると
            # リストア時の --to-dbname が無効になるため、単一DBのダンプにする）。
            # リストアは mysql "$TO_DBNAME" < dump で明示的に先を選ぶ
            MYSQL_PWD="${!DUMP_PW_ENV}" mysqldump \
                -h "$HOST" -P "$PORT" -u "$USER" \
                "$DBNAME" --no-tablespaces --column-statistics=0 \
                > "$OUT" 2>/dev/null || MYSQL_PWD="${!DUMP_PW_ENV}" mysqldump \
                -h "$HOST" -P "$PORT" -u "$USER" \
                "$DBNAME" --no-tablespaces > "$OUT"
            ;;
        *)
            _ms_err "未対応のエンジンです: ${ENGINE}（postgres / mysql 系のみ対応）"; exit 1 ;;
    esac
else
    _ms_log "既存のダンプを使います: $OUT"
fi

# DBの中身（機密）が平文で入るため所有者のみ読み取り可能にする。
# 権限設定に失敗する状態は移行を続行すべきでないので即停止する
if ! chmod 600 "$OUT" 2>/dev/null; then
    _ms_err "ダンプの権限を 600 に設定できません: $OUT"
    exit 1
fi
DUMP_SIZE=$(du -h "$OUT" | cut -f1)
_ms_log "ダンプ完了: $OUT ($DUMP_SIZE)"

# ---- リストア -------------------------------------------------------------------
if [[ -z "$TO_HOST" && -z "$TO_IDENTIFIER" ]]; then
    _ms_log "リストア先が指定されていないためダンプで終了します"
    _ms_log "  リストア: --to-host <host> または --to-identifier <RDS識別子> を指定"
    exit 0
fi

command -v psql >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1 || {
    _ms_err "psql / mysql クライアントがありません"; exit 1; }

if [[ -z "$TO_HOST" ]]; then
    _ms_log "本番AWSのRDSエンドポイントを解決しています: $TO_IDENTIFIER"
    if ! TO_HOST="$(ms_aws_real rds describe-db-instances --db-instance-identifier "$TO_IDENTIFIER" \
        --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null)"; then
        _ms_err "本番AWS上に $TO_IDENTIFIER が見つかりません（認証または識別子を確認）"; exit 1
    fi
    TO_PORT="$(ms_aws_real rds describe-db-instances --db-instance-identifier "$TO_IDENTIFIER" \
        --query 'DBInstances[0].Endpoint.Port' --output text)"
fi
: "${TO_PORT:=${PORT}}"
: "${TO_USER:=$USER}"
: "${TO_DBNAME:=${DBNAME:--}}"

_ms_log "リストア先: $TO_HOST:$TO_PORT user=$TO_USER db=$TO_DBNAME"

if [[ -z "$TO_PW_ENV" || -z "${!TO_PW_ENV:-}" ]]; then
    _ms_err "リストア先のパスワードが必要です: --to-password-env <変数名>"; exit 1
fi

if (( ! YES )); then
    read -r -p "リストアを実行しますか? (yes/no): " ans
    [[ "$ans" == "yes" ]] || { _ms_log "中断しました（ダンプは $OUT に残っています）"; exit 0; }
fi

case "$ENGINE" in
    postgres*)
        # SQLエラーがあれば即停止（部分適用を「成功」と誤認させない）
        if ! PGPASSWORD="${!TO_PW_ENV}" psql -h "$TO_HOST" -p "$TO_PORT" -U "$TO_USER" -d "$TO_DBNAME" \
            -v ON_ERROR_STOP=1 -f "$OUT"; then
            _ms_err "リストア中にSQLエラーが発生しました（途中まで適用された可能性があります）"
            _ms_err "ダンプは残しています: $OUT — 内容を確認の上、再実行してください"
            exit 1
        fi
        ;;
    mysql*)
        # mysql クライアントは非対話実行でエラー時に非ゼロで終了する
        if ! MYSQL_PWD="${!TO_PW_ENV}" mysql -h "$TO_HOST" -P "$TO_PORT" -u "$TO_USER" "$TO_DBNAME" < "$OUT"; then
            _ms_err "リストア中にSQLエラーが発生しました（途中まで適用された可能性があります）"
            _ms_err "ダンプは残しています: $OUT — 内容を確認の上、再実行してください"
            exit 1
        fi
        ;;
esac

_ms_log "リストア完了: $OUT -> $TO_HOST:$TO_PORT/$TO_DBNAME"
_ms_log "注意: シーケンス・ユーザ権限・拡張は必要に応じて本番側で調整してください（docs/04-migrate-to-aws.md）"
