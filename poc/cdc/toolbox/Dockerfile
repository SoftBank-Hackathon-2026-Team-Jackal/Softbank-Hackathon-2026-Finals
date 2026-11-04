# 스크립트 실행 환경: psql, pg_dump + 빠른 전환 스크립트(05_switchover_fast.py)용 psycopg
FROM postgres:16
RUN apt-get update && apt-get install -y --no-install-recommends python3-psycopg \
 && rm -rf /var/lib/apt/lists/*
