#!/bin/sh
# Outside heartbeat: tells healthchecks.io the server is alive, every minute.
# If the pings stop (power cut, Wi-Fi down, crash), healthchecks.io alerts from
# outside, which is the one failure the server cannot report about itself.
# The ping URL lives in /etc/homelab/healthchecks.env (root only), not in git.
set -eu
. /etc/homelab/healthchecks.env
curl -fsS -m 10 --retry 3 -o /dev/null "$HC_PING_URL"
