#!/bin/sh
# Nightly backup of everything that matters to the USB disk, with restic
# (encrypted, deduplicated snapshots). Run by homelab-backup.timer.
#
# Consistency: Nextcloud goes into maintenance mode and its database is dumped;
# Plausible's PostgreSQL is dumped; Vaultwarden, n8n (SQLite) and Plausible's
# ClickHouse are stopped for the seconds the snapshot takes.
set -eu

export RESTIC_REPOSITORY=/mnt/backup/restic
export RESTIC_PASSWORD_FILE=/root/.restic-password
STAGING=/srv/backup-staging
METRICS=/var/lib/node_exporter/textfile/backup.prom
# Stopped during the snapshot (files must not change mid-copy); started again in
# reverse order, so ClickHouse is up before the Plausible app that needs it
STOP_APPS="vaultwarden-vaultwarden-1 n8n-n8n-1 plausible-plausible-1 plausible-plausible_events_db-1"
START_APPS="plausible-plausible_events_db-1 plausible-plausible-1 n8n-n8n-1 vaultwarden-vaultwarden-1"

log() { echo "$(date -Is) $*"; }
occ() { docker exec -u www-data nextcloud-app-1 php occ "$@"; }

# The disk is mounted with nofail: if it is unplugged, stop here rather than
# writing the backup onto the internal SSD.
mountpoint -q /mnt/backup || { log "backup disk not mounted"; exit 1; }

START=$(date +%s)
mkdir -p "$STAGING"

cleanup() {
  for c in $START_APPS; do
    docker start "$c" >/dev/null 2>&1 || true
    # Plausible's app needs ClickHouse answering before it starts
    if [ "$c" = plausible-plausible_events_db-1 ]; then
      for i in $(seq 1 30); do
        docker exec "$c" wget -q -O /dev/null http://127.0.0.1:8123/ping 2>/dev/null && break
        sleep 1
      done
    fi
  done
  occ maintenance:mode --off >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "nextcloud: maintenance mode on, dumping database"
occ maintenance:mode --on
docker exec nextcloud-db-1 pg_dump -U nextcloud -d nextcloud -Fc > "$STAGING/nextcloud.pgdump"
# Nextcloud logs in as its own role (oc_admin, created by its installer), which
# pg_dump leaves out. Without it a restored database rejects Nextcloud.
docker exec nextcloud-db-1 pg_dumpall -U nextcloud --roles-only > "$STAGING/nextcloud-roles.sql"

log "plausible: dumping database"
docker exec plausible-plausible_db-1 pg_dump -U postgres -d plausible_db -Fc > "$STAGING/plausible.pgdump"

log "stopping apps with files that must not change mid-copy"
docker stop $STOP_APPS >/dev/null

log "restic backup"
restic backup --tag nightly --one-file-system \
  --exclude /srv/appdata/vaultwarden/icon_cache \
  "$STAGING" \
  /srv/data \
  /srv/appdata/nextcloud/html/config \
  /srv/appdata/nextcloud/html/custom_apps \
  /srv/appdata/nextcloud/html/themes \
  /srv/appdata/vaultwarden \
  /srv/appdata/n8n \
  /srv/appdata/portainer \
  /srv/appdata/monitoring/grafana \
  /srv/appdata/cloudflared \
  /srv/appdata/plausible/event-data \
  /srv/appdata/plausible/data \
  /srv/homelab \
  /etc \
  /root/.restic-password

cleanup
trap - EXIT
log "apps back up"

log "pruning old snapshots"
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune --quiet

END=$(date +%s)
SIZE=$(restic stats --mode raw-data --json | python3 -c "import json,sys; print(json.load(sys.stdin)['total_size'])")
SNAPSHOTS=$(restic snapshots --json | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

cat > "$METRICS.tmp" <<EOF
# HELP homelab_backup_last_success_timestamp_seconds When the last backup finished successfully.
# TYPE homelab_backup_last_success_timestamp_seconds gauge
homelab_backup_last_success_timestamp_seconds $END
# HELP homelab_backup_duration_seconds How long the last backup took.
# TYPE homelab_backup_duration_seconds gauge
homelab_backup_duration_seconds $((END - START))
# HELP homelab_backup_repo_size_bytes Size of the backup repository on disk.
# TYPE homelab_backup_repo_size_bytes gauge
homelab_backup_repo_size_bytes $SIZE
# HELP homelab_backup_snapshots Snapshots kept in the repository.
# TYPE homelab_backup_snapshots gauge
homelab_backup_snapshots $SNAPSHOTS
EOF
mv "$METRICS.tmp" "$METRICS"
rm -f "$STAGING/nextcloud.pgdump" "$STAGING/nextcloud-roles.sql" "$STAGING/plausible.pgdump"
log "done in $((END - START))s"

# Off-site copy to Cloudflare R2, once /etc/homelab/offsite.env exists (root only:
# OFFSITE_REPOSITORY, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY). "restic copy" sends
# the snapshots just made, already encrypted and only the new data, so it adds no
# downtime. A failure leaves the local backup intact and surfaces as the
# "Off-site backup overdue" alert instead of failing the whole job.
OFFSITE_ENV=/etc/homelab/offsite.env
OFFSITE_METRICS=/var/lib/node_exporter/textfile/offsite.prom
if [ -f "$OFFSITE_ENV" ]; then
  log "off-site copy to Cloudflare R2"
  # Not "if ( ... )": inside an if condition the shell ignores set -e, so a failed
  # step would not stop the subshell. Run it, then read its exit status.
  set +e
  (
    set -e
    set -a; . "$OFFSITE_ENV"; set +a
    restic -r "$OFFSITE_REPOSITORY" copy --from-repo "$RESTIC_REPOSITORY" \
      --from-password-file "$RESTIC_PASSWORD_FILE" --quiet
    restic -r "$OFFSITE_REPOSITORY" forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune --quiet
    OSIZE=$(restic -r "$OFFSITE_REPOSITORY" stats --mode raw-data --json \
      | python3 -c "import json,sys; print(json.load(sys.stdin)['total_size'])")
    cat > "$OFFSITE_METRICS.tmp" <<EOF
# HELP homelab_offsite_last_success_timestamp_seconds When the last off-site copy finished.
# TYPE homelab_offsite_last_success_timestamp_seconds gauge
homelab_offsite_last_success_timestamp_seconds $(date +%s)
# HELP homelab_offsite_repo_size_bytes Size of the off-site repository (R2 free tier: 10 GB).
# TYPE homelab_offsite_repo_size_bytes gauge
homelab_offsite_repo_size_bytes $OSIZE
EOF
    mv "$OFFSITE_METRICS.tmp" "$OFFSITE_METRICS"
  )
  RC=$?
  set -e
  if [ "$RC" = 0 ]; then log "off-site copy done"; else log "off-site copy FAILED ($RC); local backup is fine"; fi
fi
