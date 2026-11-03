# 공통 함수. 노드 이름(pg-a, pg-b)으로 접속 정보를 찾는다.
#   관리 접속:   PG_A_URL, PG_B_URL ...   (노드 이름을 대문자로, '-'를 '_'로 바꾼 뒤 _URL)
#   복제 접속:   구독자가 발행자에 접속할 때 쓰는 주소. 기본은 host=<노드 이름>
set -euo pipefail

RESULTS_DIR="${RESULTS_DIR:-/poc/results}"
LAG_OK_BYTES="${LAG_OK_BYTES:-1048576}"

log() { echo "[$(date +%H:%M:%S.%3N)] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }
now_ms() { date +%s%3N; }

url() {
  local v
  v="$(echo "$1" | tr 'a-z-' 'A-Z_')_URL"
  [[ -n "${!v:-}" ]] || die "접속 정보 $v 가 없습니다"
  echo "${!v}"
}

q() { psql "$(url "$1")" -XAtq -v ON_ERROR_STOP=1 -c "$2"; }
pgb() { psql "$PGB_ADMIN_URL" -XAtq -c "$1"; }

# 구독 이름 = mig_from_<발행자>. 슬롯 이름도 같다
sub_name() { echo "mig_from_$(echo "$1" | tr '-' '_')"; }

repl_conn() {
  local v
  v="$(echo "$1" | tr 'a-z-' 'A-Z_')_REPL_HOST"
  echo "host=${!v:-$1} port=5432 dbname=app user=replicator password=${REPL_PASSWORD}"
}

# PK가 없는 테이블에 REPLICA IDENTITY FULL 지정 (없으면 publication 생성 후 그 테이블의 UPDATE/DELETE가 실패함)
fix_replica_identity() {
  local db="$1" t
  for t in $(q "$db" "
    select format('%I.%I', n.nspname, c.relname)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.relkind = 'r' and n.nspname not in ('pg_catalog','information_schema')
      and c.relreplident = 'd'
      and not exists (select 1 from pg_index i where i.indrelid = c.oid and i.indisprimary)"); do
    log "$db: $t 에 PK가 없어 REPLICA IDENTITY FULL 지정"
    q "$db" "ALTER TABLE $t REPLICA IDENTITY FULL" >/dev/null
  done
}

# public 스키마 테이블별 "이름|행 수|해시 합". 행마다 md5 앞 64비트를 더하므로 순서와 무관하고 메모리를 거의 쓰지 않는다
checksums() {
  psql "$(url "$1")" -XAtq -v ON_ERROR_STOP=1 <<'SQL'
select format('select %L, count(*), coalesce(sum((''x'' || substr(md5(t::text), 1, 16))::bit(64)::bigint::numeric), 0) from public.%I t',
              tablename, tablename)
from pg_tables where schemaname = 'public' order by tablename \gexec
SQL
}

# PK 컬럼이 id 인 테이블별 "이름|max(id)". 인덱스만 읽으므로 데이터가 커도 빠르다 (전환 중 가벼운 검증용)
max_ids() {
  psql "$(url "$1")" -XAtq -v ON_ERROR_STOP=1 <<'SQL'
select format('select %L, coalesce(max(id), 0) from public.%I', c.relname, c.relname)
from pg_class c join pg_namespace n on n.oid = c.relnamespace
join pg_index i on i.indrelid = c.oid and i.indisprimary
join pg_attribute a on a.attrelid = c.oid and a.attnum = i.indkey[0] and a.attname = 'id'
where n.nspname = 'public' and c.relkind = 'r' order by c.relname \gexec
SQL
}

db_bytes() { q "$1" "select pg_database_size(current_database())"; }

# 발행자의 슬롯 지연량(바이트). 슬롯이 없으면 -1
slot_lag() {
  q "$1" "select coalesce(max(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)), -1)::bigint
          from pg_replication_slots where slot_name = '$2'"
}

pgb_target() { sed -n 's/^app = host=\([^ ]*\).*/\1/p' "$PGB_RUNTIME/databases.ini"; }
pgb_set_target() { printf '[databases]\napp = host=%s port=5432 dbname=app\n' "$1" > "$PGB_RUNTIME/databases.ini"; }
