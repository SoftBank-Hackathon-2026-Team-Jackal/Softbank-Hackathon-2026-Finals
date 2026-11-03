#!/bin/sh
set -e
RUNTIME=/etc/pgbouncer/runtime/databases.ini
mkdir -p "$(dirname "$RUNTIME")"
if [ ! -f "$RUNTIME" ]; then
  printf '[databases]\napp = host=pg-a port=5432 dbname=app\n' > "$RUNTIME"
fi
chmod 666 "$RUNTIME"
exec pgbouncer -u postgres /etc/pgbouncer/pgbouncer.ini
