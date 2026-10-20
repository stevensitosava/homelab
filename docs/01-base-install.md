# 01 · Base install: Ubuntu Server on a Wi-Fi-only laptop

**Hardware:** Lenovo IdeaPad 3 15IIL05 (2020). Intel Core i3-1005G1 (2 cores, 4 threads),
8 GB RAM, 256 GB NVMe SSD, Intel Wi-Fi 6 (CNVi). No Ethernet port, so the server runs on Wi-Fi.

**OS:** Ubuntu Server 26.04.1 LTS, kernel 7.0, no desktop.

The install hit two Wi-Fi problems that stack on top of each other. Both are fixed
permanently by files in [`host/`](../host).

---

## Problem 1 · "error triggering scan failed -100"

**Symptom.** The installer's network screen could not list Wi-Fi networks.

**Diagnosis.** `-100` is `ENETDOWN`: the interface was down when the scan ran. The
installer has no `rfkill` tool, so I read the kernel's radio state from sysfs instead:

```bash
grep . /sys/class/rfkill/*/name /sys/class/rfkill/*/soft /sys/class/rfkill/*/hard
```

Every radio (`ideapad_wlan`, `ideapad_bluetooth`, `phy0`, `hci0`) reported `soft:1`,
`hard:0`. That is software airplane mode, not a physical switch.

**Fix.** In the installer shell:

```bash
for f in /sys/class/rfkill/*/soft; do echo 0 > $f; done
```

The block came back on the first boot of the installed system, so the permanent fix is a
udev rule that unblocks each radio as it appears:
[`80-rfkill-unblock.rules`](../host/etc/udev/rules.d/80-rfkill-unblock.rules).

---

## Problem 2 · Radio on, but it never joins the network

**Symptom.** After unblocking, `ip addr` showed the interface `UP` but `NO-CARRIER`, and
`systemctl status netplan-wpa-wlp0s20f3` said the unit did not exist. No Wi-Fi
supplicant was running at all.

**Diagnosis.** Running `netplan apply` by hand surfaced the real error:

```
ERROR: wlp0s20f3: networkd backend does not support wifi with match:, only by interface name
```

The 26.04.1 installer writes its Wi-Fi config with a `match:` block. The networkd backend
cannot start `wpa_supplicant` for a matched interface, so netplan failed and the
installer's screen just kept waiting.

**Fix.** Move the installer's netplan files aside and write the config keyed by interface
name ([`99-wifi.yaml.example`](../host/etc/netplan/99-wifi.yaml.example)), then
`netplan apply`.

One more catch: `wpa_cli status` then sat at `wpa_state=SCANNING` with no connection
attempts in the log, which means no visible network matched the configured name. A
one-character typo in the network name; `wpa_cli scan_results` shows the exact spelling.

**Carrying the fix into the installed system.** Before the first reboot, from the
installer shell (the new system is mounted at `/target`):

```bash
mkdir -p /target/root/netplan-installer && mv /target/etc/netplan/*.yaml /target/root/netplan-installer/
cp /etc/netplan/99-wifi.yaml /target/etc/netplan/ && chmod 600 /target/etc/netplan/99-wifi.yaml
echo 'network: {config: disabled}' > /target/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
ls -l /target/usr/sbin/wpa_supplicant   # confirm the supplicant was installed
```

The cloud-init line stops it from regenerating the broken config on first boot.

---

## Host configuration

| What | How | Verified by |
|---|---|---|
| SSH key-only, no root login | [`00-hardening.conf`](../host/etc/ssh/sshd_config.d/00-hardening.conf). The `00-` prefix matters: the installer's `50-cloud-init.conf` sets `PasswordAuthentication yes`, and sshd keeps the first value it reads. | A password-only login attempt returns `Permission denied (publickey)` |
| Keeps running with the lid closed | [`lid.conf`](../host/etc/systemd/logind.conf.d/lid.conf) logind drop-in | `HandleLidSwitch` reads `ignore` after reboot |
| Screen off when idle | The console never blanks by default, so the panel stayed lit at full brightness. `consoleblank=60` via a [GRUB drop-in](../host/etc/default/grub.d/90-homelab-consoleblank.cfg) | `/sys/class/drm/card1-eDP-1/dpms` reads `Off` a minute after the last keypress |
| Battery kept at ~60% | Lenovo conservation mode: `echo 1 > /sys/bus/platform/drivers/ideapad_acpi/VPC2004:00/conservation_mode`. Stored in firmware. | Survives reboot; battery at 74% reports `Not charging` |
| Full disk for `/` | The installer's LVM layout gave `/` only 100 of 235 GB: `lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv` | `df -h /` shows 232 GB |
| Remote access | Tailscale, key expiry disabled for this machine | SSH by Tailscale name |
| Security updates | `unattended-upgrades` (Ubuntu default) | `systemctl is-active unattended-upgrades` |

**Reboot test.** Rebooted remotely and waited for the kernel `boot_id` to change, so a
check could not pass against the old boot. Wi-Fi reconnected by itself, all radios
unblocked, conservation mode and lid setting held, Docker and Tailscale came up, and
`systemctl --failed` was empty.
