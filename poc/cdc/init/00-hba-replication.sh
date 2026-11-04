#!/bin/bash
# 물리 복제(pg_basebackup, 06_physical_copy.sh)용 접속 허용. 도커 이미지 기본값은 localhost 에서만 replication 을 받는다.
# pg_createsubscriber 는 대기 서버의 접속 정보를 -P 로 준 계정(postgres)으로 바꾸므로 replicator 만 허용하면 따라잡지 못한다
echo "host replication all all scram-sha-256" >> "$PGDATA/pg_hba.conf"
