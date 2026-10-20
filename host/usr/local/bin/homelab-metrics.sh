#!/bin/sh
# Extra metrics node_exporter does not collect on its own, written in the
# Prometheus text format for its textfile collector. Run by homelab-metrics.timer.
set -eu

OUT_DIR=/var/lib/node_exporter/textfile
TMP="$OUT_DIR/homelab.prom.$$"
mkdir -p "$OUT_DIR"

{
  # Wi-Fi signal (dBm) and link quality from /proc/net/wireless
  awk 'BEGIN {
    print "# HELP homelab_wifi_signal_dbm Wi-Fi signal level."
    print "# TYPE homelab_wifi_signal_dbm gauge"
  }
  NR > 2 {
    gsub(":", "", $1); gsub("\\.", "", $3); gsub("\\.", "", $4)
    printf "homelab_wifi_signal_dbm{interface=\"%s\"} %s\n", $1, $4
    q[$1] = $3
  }
  END {
    print "# HELP homelab_wifi_link_quality Wi-Fi link quality (0-70)."
    print "# TYPE homelab_wifi_link_quality gauge"
    for (i in q) printf "homelab_wifi_link_quality{interface=\"%s\"} %s\n", i, q[i]
  }' /proc/net/wireless

  # Lenovo battery conservation mode (charging stops around 60%)
  CM=/sys/bus/platform/drivers/ideapad_acpi/VPC2004:00/conservation_mode
  if [ -r "$CM" ]; then
    echo "# HELP homelab_battery_conservation_mode 1 if Lenovo conservation mode is on."
    echo "# TYPE homelab_battery_conservation_mode gauge"
    echo "homelab_battery_conservation_mode $(cat "$CM")"
  fi

  # Backup disk present? (the backup job refuses to run without it)
  echo "# HELP homelab_backup_disk_mounted 1 if the backup disk is mounted at /mnt/backup."
  echo "# TYPE homelab_backup_disk_mounted gauge"
  if mountpoint -q /mnt/backup; then echo "homelab_backup_disk_mounted 1"; else echo "homelab_backup_disk_mounted 0"; fi

  # One series per container: 1 if running, 0 otherwise
  echo "# HELP homelab_container_running 1 if the container is running."
  echo "# TYPE homelab_container_running gauge"
  docker ps -a --format '{{.Names}} {{.State}}' | while read -r name state; do
    [ "$state" = "running" ] && up=1 || up=0
    echo "homelab_container_running{name=\"$name\"} $up"
  done
} > "$TMP"

# Atomic replace, so node_exporter never reads a half-written file
mv "$TMP" "$OUT_DIR/homelab.prom"

# Backup disk health (SMART), at most once an hour. "-n standby" skips the read
# if the disk is asleep, so the check never spins it up on its own.
SMART="$OUT_DIR/smart.prom"
AGE=3600
[ -f "$SMART" ] && AGE=$(( $(date +%s) - $(stat -c %Y "$SMART") ))
DEV=$(findmnt -no SOURCE /mnt/backup 2>/dev/null | sed 's/[0-9]*$//')
if [ "$AGE" -ge 3600 ] && [ -n "$DEV" ] && command -v smartctl >/dev/null; then
  RAW=$(smartctl -n standby -H -A "$DEV" 2>/dev/null || true)
  if echo "$RAW" | grep -q "overall-health"; then
    PASSED=0; echo "$RAW" | grep -q "overall-health.*PASSED" && PASSED=1
    attr() { echo "$RAW" | awk -v n="$1" '$2 == n { print $10 + 0; found=1 } END { if (!found) print 0 }'; }
    L="device=\"$(basename "$DEV")\""
    {
      echo "# HELP homelab_disk_smart_passed 1 if the disk's SMART self-assessment passed."
      echo "# TYPE homelab_disk_smart_passed gauge"
      echo "homelab_disk_smart_passed{$L} $PASSED"
      echo "# HELP homelab_disk_reallocated_sectors Sectors the disk has replaced (growing = failing)."
      echo "# TYPE homelab_disk_reallocated_sectors gauge"
      echo "homelab_disk_reallocated_sectors{$L} $(attr Reallocated_Sector_Ct)"
      echo "# HELP homelab_disk_pending_sectors Unreadable sectors waiting to be replaced."
      echo "# TYPE homelab_disk_pending_sectors gauge"
      echo "homelab_disk_pending_sectors{$L} $(attr Current_Pending_Sector)"
      echo "# HELP homelab_disk_temperature_celsius Disk temperature."
      echo "# TYPE homelab_disk_temperature_celsius gauge"
      echo "homelab_disk_temperature_celsius{$L} $(attr Temperature_Celsius)"
      echo "# HELP homelab_disk_power_on_hours Hours the disk has been powered on."
      echo "# TYPE homelab_disk_power_on_hours gauge"
      echo "homelab_disk_power_on_hours{$L} $(attr Power_On_Hours)"
    } > "$SMART.tmp" && mv "$SMART.tmp" "$SMART"
  fi
fi
