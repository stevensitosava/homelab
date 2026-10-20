#!/usr/bin/env python3
"""Run the power model's awk program from homelab-metrics.sh on synthetic readings and
check the edge cases: counter wrap, reboot, long gap, battery, first run. The first case
is wrong on purpose, to prove a failing case is reported.

Usage: python3 scripts/test-power-model.py   (needs awk; exits 1 on any failure)
"""
import re
import subprocess
import tempfile
from pathlib import Path

src = (Path(__file__).resolve().parent.parent / "host/usr/local/bin/homelab-metrics.sh").read_text()
prog = re.search(r"-v state=\"\$STATE\.tmp\" '\n(.*?)\n  }' >", src, re.S).group(1) + "\n  }"
MAX = 262143328850
BOOT = "b1"


def run(last, now, uj, ac=1, batw=0, boot=BOOT):
    with tempfile.TemporaryDirectory() as d:
        st = Path(d) / "state"
        out = subprocess.run(["awk", "-v", f"now={now}", "-v", f"uj={uj}", "-v", f"max={MAX}",
                              "-v", f"ac={ac}", "-v", f"batw={batw}", "-v", f"boot={boot}",
                              "-v", f"last={last}", "-v", "base=3.2", "-v", "eff=0.80",
                              "-v", f"state={st.as_posix()}", prog],
                             capture_output=True, text=True, check=True).stdout
        m = dict(re.findall(r"^(homelab_\w+) ([\d.]+)$", out, re.M))
        return {k: float(v) for k, v in m.items()}, st.read_text().split()


cases = [
    # name, last state, call kwargs, expected wall W (None = no sample), expected total
    ("SELF-TEST (wrong on purpose)", f"1000 0 0 {BOOT}", dict(now=1015, uj=30e6), 99.0, None),
    ("normal 15 s at 2 W", f"1000 0 0 {BOOT}", dict(now=1015, uj=30e6), (2 + 3.2) / 0.8, 15 * (2 + 3.2) / 0.8),
    ("RAPL counter wraps", f"1000 {MAX - 10e6} 50 {BOOT}", dict(now=1010, uj=10e6), (2 + 3.2) / 0.8, 50 + 10 * (2 + 3.2) / 0.8),
    ("reboot (new boot id)", f"1000 5e9 50 {BOOT}", dict(now=1015, uj=1e6, boot="b2"), None, 50),
    ("gap of 5 minutes", f"1000 0 50 {BOOT}", dict(now=1300, uj=600e6), None, 50),
    ("on battery 5 W", f"1000 0 0 {BOOT}", dict(now=1015, uj=30e6, ac=0, batw=5e6), 5 / 0.8, 15 * 5 / 0.8),
    ("first run, no state", "0 0 0 none", dict(now=1015, uj=30e6), None, 0),
]
fails = 0
for name, last, kw, want_w, want_total in cases:
    m, state = run(last, **kw)
    got_w, got_total = m.get("homelab_power_wall_watts"), m["homelab_energy_wall_joules_total"]
    ok = (got_w is None if want_w is None else got_w is not None and abs(got_w - want_w) < 0.01) \
        and (want_total is None or abs(got_total - want_total) < 0.01) and state[3] == kw.get("boot", BOOT)
    expect_fail = name.startswith("SELF-TEST")
    verdict = ("caught, as it should be" if not ok else "NOT CAUGHT") if expect_fail else ("ok" if ok else "FAIL")
    fails += (ok if expect_fail else not ok)
    print(f"{name:<30} wall={got_w} total={got_total:.2f} measured={m['homelab_power_wall_measured']:.0f}  -> {verdict}")
print("FAILURES:", fails)
raise SystemExit(1 if fails else 0)
