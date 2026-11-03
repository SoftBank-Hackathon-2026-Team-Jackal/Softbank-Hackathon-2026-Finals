#!/usr/bin/env bash
# 시나리오 3: 복제 중 구독자(pg-b)를 멈췄다가 다시 켠다
# 확인할 것: 멈춘 동안 pg-a의 슬롯이 WAL을 붙잡아 지연량이 늘고, 재시작 후 따라잡아 데이터가 일치하는지
source "$(dirname "$0")/common.sh"

fresh_start
start_load 2
$T 01_copy_schema.sh pg-a pg-b
$T 02_start_replication.sh pg-a pg-b
$T 03_wait_sync.sh pg-a pg-b 2>/dev/null

step "pg-b 중지 (20초)"
docker compose stop pg-b >/dev/null
for i in 1 2 3 4; do
  sleep 5
  docker compose exec -T pg-a psql -U postgres -d app -Atc \
    "select format('슬롯 %s: active=%s, 붙잡은 WAL=%s', slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))) from pg_replication_slots where slot_name = 'mig_from_pg_a'"
done

step "pg-b 재시작 → 따라잡기"
docker compose start pg-b >/dev/null
docker compose up -d --wait pg-b >/dev/null
$T 03_wait_sync.sh pg-a pg-b 120
stop_load
$T 03_wait_sync.sh pg-a pg-b 60 2>/dev/null
$T 07_check_lost.sh pg-b
$T 04_compare.sh pg-a pg-b
