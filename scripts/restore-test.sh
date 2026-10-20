#!/bin/sh
# Restore drill: restore the latest snapshot into a scratch folder and prove the
# data is usable, without touching the live services. Run as root on the server:
#   sudo sh restore-test.sh
# Checks: Nextcloud database dump restores into a throwaway PostgreSQL and its
# row counts match live; user files match live; the SQLite apps open; config intact.
set -eu

export RESTIC_REPOSITORY=/mnt/backup/restic
export RESTIC_PASSWORD_FILE=/root/.restic-password
export RESTIC_CACHE_DIR=/var/cache/restic
# "--offsite" drills the Cloudflare R2 copy instead of the USB disk
if [ "${1:-}" = "--offsite" ]; then
  set -a; . /etc/homelab/offsite.env; set +a
  export RESTIC_REPOSITORY="$OFFSITE_REPOSITORY"
  echo "drilling the OFF-SITE copy"
fi
DEST=/tmp/restore-test
PG=restore-test-pg
FAIL=0

check() { # name, expected, actual
  if [ "$2" = "$3" ]; then echo "  ok    $1: $3"; else echo "  FAIL  $1: expected $2, got $3"; FAIL=1; fi
}
sqlite_count() { python3 -c "import sqlite3,sys; print(sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True).execute(sys.argv[2]).fetchone()[0])" "$1" "$2"; }

# A checker that cannot fail proves nothing: make sure a mismatch is reported
( check "self-test" 1 2 ) | grep -q FAIL || { echo "checker cannot detect a mismatch"; exit 1; }

rm -rf "$DEST"; docker rm -f "$PG" >/dev/null 2>&1 || true
START=$(date +%s)

echo "1. restore latest snapshot"
restic restore latest --target "$DEST" --quiet
echo "  restored $(du -sh "$DEST" | cut -f1) in $(( $(date +%s) - START ))s"

echo "2. Nextcloud database into a throwaway PostgreSQL"
docker run -d --name "$PG" -e POSTGRES_PASSWORD=restoretest -e POSTGRES_USER=nextcloud -e POSTGRES_DB=nextcloud postgres:18-alpine >/dev/null
until docker exec "$PG" pg_isready -U nextcloud -d nextcloud >/dev/null 2>&1; do sleep 1; done
sleep 2
# Roles first (Nextcloud's own oc_admin login), then the data. "role nextcloud
# already exists" is expected: the throwaway container creates it.
docker exec -i "$PG" psql -q -U nextcloud -d nextcloud < "$DEST/srv/backup-staging/nextcloud-roles.sql" 2>&1 \
  | grep -v 'role "nextcloud" already exists' || true
docker exec -i "$PG" pg_restore -U nextcloud -d nextcloud < "$DEST/srv/backup-staging/nextcloud.pgdump" \
  || { echo "  FAIL  pg_restore reported errors"; FAIL=1; }
DBUSER=$(grep "'dbuser'" "$DEST/srv/appdata/nextcloud/html/config/config.php" | sed -E "s/.*=> '([^']+)'.*/\1/")
check "Nextcloud's DB login ($DBUSER) can read its tables" "t" \
  "$(docker exec "$PG" psql -U nextcloud -d nextcloud -tAc "select has_table_privilege('$DBUSER','oc_users','SELECT')" 2>/dev/null || echo missing)"
for t in oc_users oc_filecache oc_appconfig; do
  LIVE=$(docker exec nextcloud-db-1 psql -U nextcloud -d nextcloud -tAc "select count(*) from $t")
  REST=$(docker exec "$PG" psql -U nextcloud -d nextcloud -tAc "select count(*) from $t")
  check "rows in $t" "$LIVE" "$REST"
done

echo "3. Nextcloud user files and config"
check "user files" "$(find /srv/data/nextcloud -type f | wc -l)" "$(find "$DEST/srv/data/nextcloud" -type f | wc -l)"
LIVE_ID=$(grep "'instanceid'" /srv/appdata/nextcloud/html/config/config.php)
REST_ID=$(grep "'instanceid'" "$DEST/srv/appdata/nextcloud/html/config/config.php")
check "config.php instanceid" "$LIVE_ID" "$REST_ID"

echo "4. SQLite apps"
check "Vaultwarden accounts" "$(sqlite_count /srv/appdata/vaultwarden/db.sqlite3 'select count(*) from users')" \
  "$(sqlite_count "$DEST/srv/appdata/vaultwarden/db.sqlite3" 'select count(*) from users')"
check "n8n users" "$(sqlite_count /srv/appdata/n8n/database.sqlite 'select count(*) from user')" \
  "$(sqlite_count "$DEST/srv/appdata/n8n/database.sqlite" 'select count(*) from user')"

echo "5. Plausible"
# Plausible connects as the "postgres" superuser, so ownership is not an issue here
docker exec "$PG" psql -q -U nextcloud -d nextcloud -c "create database plausible_db" >/dev/null
docker exec -i "$PG" pg_restore -U nextcloud -d plausible_db --no-owner < "$DEST/srv/backup-staging/plausible.pgdump" \
  || { echo "  FAIL  Plausible pg_restore reported errors"; FAIL=1; }
for t in users sites; do
  check "Plausible rows in $t" \
    "$(docker exec plausible-plausible_db-1 psql -U postgres -d plausible_db -tAc "select count(*) from $t")" \
    "$(docker exec "$PG" psql -U nextcloud -d plausible_db -tAc "select count(*) from $t")"
done
[ -d "$DEST/srv/appdata/plausible/event-data/store" ] && echo "  ok    Plausible event store present ($(du -sh "$DEST/srv/appdata/plausible/event-data" | cut -f1))" \
  || { echo "  FAIL  Plausible event store missing"; FAIL=1; }

echo "6. keys needed to rebuild"
for f in srv/appdata/cloudflared/homelab.json srv/homelab/services/n8n/.env root/.restic-password; do
  [ -s "$DEST/$f" ] && echo "  ok    present: /$f" || { echo "  FAIL  missing: /$f"; FAIL=1; }
done

TOTAL=$(( $(date +%s) - START ))
docker rm -f "$PG" >/dev/null; rm -rf "$DEST"
echo "restore drill finished in ${TOTAL}s, result: $([ $FAIL = 0 ] && echo PASS || echo FAIL)"
exit $FAIL
