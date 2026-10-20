#!/usr/bin/env python3
"""Run every query in a Grafana dashboard against Prometheus and report empty ones.

Usage: check-dashboard.py DASHBOARD.json [PROMETHEUS_URL]
Exits 1 if any query errors or returns no data.
"""
import json
import sys
import urllib.parse
import urllib.request

# Empty until the Cloudflare R2 off-site copy is configured (/etc/homelab/offsite.env)
ALLOWED_EMPTY = {"Off-site copy", "Off-site size"}


def query(prom, expr, variables=None):
    expr = expr.replace("$__rate_interval", "1m")
    # Dashboard variables (e.g. the electricity price) are tested at their default value
    for name in sorted(variables or {}, key=len, reverse=True):
        expr = expr.replace("${%s}" % name, variables[name]).replace("$" + name, variables[name])
    url = prom + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    with urllib.request.urlopen(url, timeout=10) as r:
        body = json.load(r)
    if body.get("status") != "success":
        return None, body.get("error", "error")
    return body["data"]["result"], None


def main():
    path = sys.argv[1]
    prom = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:9090"

    # Self-test: the checker must flag a metric that does not exist
    result, _ = query(prom, "homelab_metric_that_does_not_exist")
    if result:
        print("SELF-TEST FAILED: a missing metric returned data")
        return 1
    print("self-test ok: a missing metric is reported as empty")

    with open(path, encoding="utf-8") as f:
        dashboard = json.load(f)
    variables = {v["name"]: v["current"]["value"] for v in dashboard.get("templating", {}).get("list", [])}

    failures = 0
    for panel in dashboard["panels"]:
        for target in panel.get("targets", []):
            result, error = query(prom, target["expr"], variables)
            if error:
                status, failures = "ERROR " + error, failures + 1
            elif not result:
                if panel["title"] in ALLOWED_EMPTY:
                    status = "empty (allowed)"
                else:
                    status, failures = "EMPTY", failures + 1
            else:
                value = result[0]["value"][1]
                status = "ok  %s series, first = %s" % (len(result), value)
            print("%-30s %-3s %s" % (panel["title"][:30], target["refId"], status))

    print("FAILURES:", failures)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
