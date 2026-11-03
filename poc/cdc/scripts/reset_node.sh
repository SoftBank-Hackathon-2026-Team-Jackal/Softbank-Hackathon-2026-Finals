#!/usr/bin/env bash
# 사용법: RESET_OK=yes reset_node.sh <노드>
# 원격 노드(docker compose down -v 로 지울 수 없는 DB)를 시나리오 시작 전 상태로 되돌린다.
# 구독, 슬롯, publication, app 스키마를 모두 지우므로 PoC DB에만 쓴다.
source "$(dirname "$0")/lib.sh"
db="${1:?노드}"
[[ "${RESET_OK:-}" == yes ]] || die "RESET_OK=yes 가 필요합니다 ($db 의 데이터를 모두 지웁니다)"

for s in $(q "$db" "select subname from pg_subscription"); do
  # 발행자가 이미 지워졌을 수 있으므로 슬롯 연결을 끊고 지운다
  q "$db" "ALTER SUBSCRIPTION $s DISABLE" >/dev/null
  q "$db" "ALTER SUBSCRIPTION $s SET (slot_name = NONE)" >/dev/null
  q "$db" "DROP SUBSCRIPTION $s" >/dev/null
done
q "$db" "select pg_drop_replication_slot(slot_name) from pg_replication_slots where not active" >/dev/null
q "$db" "DROP PUBLICATION IF EXISTS mig_pub;
         DROP SCHEMA IF EXISTS mig CASCADE;
         DROP SCHEMA public CASCADE;
         CREATE SCHEMA public AUTHORIZATION pg_database_owner;
         GRANT USAGE ON SCHEMA public TO PUBLIC;
         GRANT CREATE ON SCHEMA public TO app;" >/dev/null
log "$db 초기화 완료"
