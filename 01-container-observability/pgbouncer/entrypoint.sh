#!/bin/bash
# entrypoint.sh

fetch_and_write() {
  TOKEN=$(curl -s "$IDENTITY_ENDPOINT?resource=https://ossrdbms-aad.database.windows.net&api-version=2019-08-01&client_id=$PG_IDENTITY_CLIENT_ID" \
    -H "X-IDENTITY-HEADER: $IDENTITY_HEADER" | python3 -c "import sys, json; print(json.load(sys.stdin)['access_token'])")
  {
    echo "\"admin\" \"localadminpass\""
    echo "\"app\" \"clienttoken\""
    echo "\"id-postgres-auth\" \"$TOKEN\""
  } > /etc/pgbouncer/userlist.txt
}

# Block here until the first real token is in place
fetch_and_write

# Only now start the background refresh loop for later cycles
(
  while true; do
    sleep 2700
    fetch_and_write
    psql "host=127.0.0.1 port=6432 dbname=pgbouncer user=admin password=localadminpass" -c "RELOAD;" > /dev/null 2>&1
  done
) &

exec pgbouncer /etc/pgbouncer/pgbouncer.ini