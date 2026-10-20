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

# Electricity: an ESTIMATE of what the laptop draws at the wall, for the cost
# panels. On the charger the battery reports 0 W (conservation mode holds it at
# ~60%), so nothing measures wall power directly. Model:
#   wall W = (CPU package W, measured by Intel RAPL, + BASE_W) / EFF
# BASE_W is the rest of the laptop (RAM, NVMe, Wi-Fi, board) plus the USB backup
# disk asleep. Calibrated 2026-10-20: on battery the whole laptop drew 4.46 W at
# 0.07 busy cores, where RAPL puts the package at ~1.7 W (fit over 16 samples:
# 1.54 W + 2.34 W per busy core), so the rest is ~2.75 W; plus ~0.5 W assumed for
# the sleeping USB disk and its bridge. EFF is the charger's efficiency at ~10%
# load (the EU minimum there is ~79%). On battery, the measured battery draw
# replaces the model. The running total survives restarts in $STATE; a reboot or
# a gap over 2 minutes is not counted.
BASE_W=3.2
EFF=0.80
RAPL=/sys/class/powercap/intel-rapl:0
STATE=/var/lib/homelab/power.state
if [ -r "$RAPL/energy_uj" ]; then
  mkdir -p "${STATE%/*}"
  LAST="0 0 0 none"
  [ -f "$STATE" ] && LAST=$(cat "$STATE")
  awk -v now="$(date +%s.%N)" -v uj="$(cat "$RAPL/energy_uj")" -v max="$(cat "$RAPL/max_energy_range_uj")" \
      -v ac="$(cat /sys/class/power_supply/ADP0/online 2>/dev/null || echo 1)" \
      -v batw="$(cat /sys/class/power_supply/BAT0/power_now 2>/dev/null || echo 0)" \
      -v boot="$(cat /proc/sys/kernel/random/boot_id)" -v last="$LAST" \
      -v base="$BASE_W" -v eff="$EFF" -v state="$STATE.tmp" '
  BEGIN {
    split(last, l, " ")   # last timestamp, last RAPL reading, running total (J), boot id
    total = l[3] + 0; dt = now - l[1]
    ok = (l[4] == boot && dt > 0 && dt <= 120)
    if (ok) { d = uj - l[2]; if (d < 0) d += max; pkg = d / dt / 1e6 }
    measured = (ac == 0 && batw > 0)
    if (ok) { wall = (measured ? batw / 1e6 : pkg + base) / eff; total += wall * dt }
    printf "%s %s %.3f %s\n", now, uj, total, boot > state
    print "# HELP homelab_power_cpu_package_watts CPU package power (Intel RAPL)."
    print "# TYPE homelab_power_cpu_package_watts gauge"
    if (ok) printf "homelab_power_cpu_package_watts %.3f\n", pkg
    print "# HELP homelab_power_wall_watts Estimated power drawn at the wall (model in homelab-metrics.sh)."
    print "# TYPE homelab_power_wall_watts gauge"
    if (ok) printf "homelab_power_wall_watts %.3f\n", wall
    print "# HELP homelab_power_wall_measured 1 while on battery (measured draw), 0 while the model is used."
    print "# TYPE homelab_power_wall_measured gauge"
    printf "homelab_power_wall_measured %d\n", measured
    print "# HELP homelab_energy_wall_joules_total Estimated energy drawn at the wall since tracking began."
    print "# TYPE homelab_energy_wall_joules_total counter"
    printf "homelab_energy_wall_joules_total %.3f\n", total
  }' > "$OUT_DIR/power.prom.tmp"
  mv "$STATE.tmp" "$STATE"
  mv "$OUT_DIR/power.prom.tmp" "$OUT_DIR/power.prom"
fi
