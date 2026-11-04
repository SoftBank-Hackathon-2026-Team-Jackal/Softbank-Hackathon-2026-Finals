#!/usr/bin/env bash
# pg-b-clone 컨테이너 안에서 실행한다 (pg-b 는 멈춘 상태, 데이터 디렉터리를 같이 씀). notes/cdc-short-switchover.md B1
#   1. pg_basebackup     원본의 디스크 블록(인덱스 포함)을 그대로 복사하고 물리 대기 서버 설정(-R)을 남긴다
#   2. pg_createsubscriber  대기 서버를 따라잡게 한 뒤, 원본에 publication 과 슬롯을 만들고
#                           그 슬롯 위치에서 승격해 논리 구독자로 바꾼다 (구독 이름과 슬롯 이름은 기존 스크립트와 같게)
# 결과: results/physical-clone.json
set -euo pipefail
log() { echo "[$(date +%H:%M:%S.%3N)] $*" >&2; }
now_ms() { date +%s%3N; }
sub=mig_from_$(echo "$SRC_HOST" | tr '-' '_')

t0=$(now_ms)
log "1. pg_basebackup ($SRC_HOST → $PGDATA)"
find "$PGDATA" -mindepth 1 -delete
PGPASSWORD="$REPL_PASSWORD" pg_basebackup -h "$SRC_HOST" -U replicator -D "$PGDATA" -X stream -c fast -R
t1=$(now_ms)
bytes=$(du -sb "$PGDATA" | cut -f1)
log "   $((bytes / 1024 / 1024))MB, $(( (t1 - t0) / 1000 ))초"

log "2. pg_createsubscriber (구독 $sub)"
pg_createsubscriber -D "$PGDATA" -U postgres -s /tmp \
  -P "host=$SRC_HOST port=5432 dbname=app user=postgres password=$PUB_PASSWORD" \
  -d app -t 300 --publication mig_pub --subscription "$sub" --replication-slot "$sub" 2>&1 \
  | grep -vE "^pg_createsubscriber: (checking|validating)" >&2 || { log "pg_createsubscriber 실패"; exit 1; }
t2=$(now_ms)
log "   $(( (t2 - t1) / 1000 ))초"

printf '{"bytes":%s,"basebackup_ms":%s,"createsubscriber_ms":%s,"total_ms":%s}\n' \
  "$bytes" $((t1 - t0)) $((t2 - t1)) $((t2 - t0)) | tee /poc/results/physical-clone.json
