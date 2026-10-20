#!/bin/sh
# Whole-homelab health check. Run on the server:  sh health-check.sh
# Prints one line per check and exits 1 if anything failed.
FAIL=0
ok()  { printf "  ok    %s\n" "$1"; }
bad() { printf "  FAIL  %s\n" "$1"; FAIL=1; }
is()  { if [ "$2" = "$3" ]; then ok "$1: $3"; else bad "$1: expected $2, got $3"; fi; }
prom() { curl -s 127.0.0.1:9090/api/v1/query --data-urlencode "query=$1" \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 'none')"; }

echo "Host"
ok "up $(uptime -p | sed 's/^up //')"
IP=$(ip -4 -o addr show wlp0s20f3 | awk '{print $4}')
[ -n "$IP" ] && ok "Wi-Fi $IP" || bad "Wi-Fi has no address"
is "radios unblocked" "0" "$(cat /sys/class/rfkill/*/soft | sort -u | tr '\n' ' ' | sed 's/ $//')"
is "lid ignored" '"ignore"' "$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch | cut -d' ' -f2)"
is "battery conservation" "1" "$(cat /sys/bus/platform/drivers/ideapad_acpi/VPC2004:00/conservation_mode)"
[ "$(cat /sys/class/power_supply/ADP0/online)" = 1 ] && ok "charger connected" || bad "running on battery ($(cat /sys/class/power_supply/BAT0/capacity)%)"
FAILED=$(systemctl --failed --no-legend | wc -l); is "failed systemd units" "0" "$FAILED"

echo "Containers"
TOTAL=$(docker ps -a -q | wc -l); RUNNING=$(docker ps -q | wc -l)
is "running" "$TOTAL" "$RUNNING"

echo "Services (probed every 30 s)"
is "probes down" "0" "$(prom 'count(probe_success{job="services"} == 0) or vector(0)')"
is "probes total" "9" "$(prom 'count(probe_success{job="services"})')"
CONN=$(prom 'cloudflared_tunnel_ha_connections')
[ "$CONN" != none ] && [ "$CONN" -ge 1 ] && ok "Cloudflare Tunnel connections: $CONN" || bad "Cloudflare Tunnel connections: $CONN"
# Nextcloud 443, n8n 5678, Vaultwarden 7443, Grafana 8443, Portainer 9443
is "Tailscale HTTPS ports" "5" "$(tailscale serve status 2>/dev/null | grep -c '^https://')"

echo "Backups"
mountpoint -q /mnt/backup && ok "backup disk mounted" || bad "backup disk NOT mounted"
NEXT=$(systemctl show homelab-backup.timer -p NextElapseUSecRealtime --value)
[ -n "$NEXT" ] && ok "next backup: $NEXT" || bad "backup timer not scheduled"
AGE=$(prom 'floor((time() - homelab_backup_last_success_timestamp_seconds) / 3600)')
[ "$AGE" != none ] && [ "$AGE" -le 26 ] && ok "last backup ${AGE} h ago" || bad "last backup: $AGE h ago"

if [ -f /etc/homelab/offsite.env ]; then
  OAGE=$(prom 'floor((time() - homelab_offsite_last_success_timestamp_seconds) / 3600)')
  [ "$OAGE" != none ] && [ "$OAGE" -le 26 ] && ok "off-site copy ${OAGE} h ago" || bad "off-site copy: $OAGE h ago"
else
  ok "off-site copy: not set up yet (optional)"
fi

echo "Outside heartbeat (healthchecks.io)"
HB=$(systemctl show homelab-heartbeat.service -p Result --value)
LAST=$(systemctl show homelab-heartbeat.service -p ExecMainExitTimestamp --timestamp=unix --value | tr -d '@')
SINCE=$(( $(date +%s) - ${LAST:-0} ))
[ "$HB" = success ] && [ "$SINCE" -le 180 ] && ok "last ping ${SINCE}s ago: $HB" || bad "heartbeat: result $HB, ${SINCE}s since last run"

echo "Alerts"
FIRING=$(curl -s 127.0.0.1:3000/api/prometheus/grafana/api/v1/rules | python3 -c "
import json,sys
d=json.load(sys.stdin)['data']['groups']
print(sum(1 for g in d for r in g['rules'] if r['state']=='firing'), sum(len(g['rules']) for g in d))")
is "rules firing (of $(echo $FIRING | cut -d' ' -f2))" "0" "$(echo $FIRING | cut -d' ' -f1)"

echo
[ $FAIL = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $FAIL
