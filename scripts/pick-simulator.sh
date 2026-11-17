#!/bin/bash
# Prints the identifier of an available iPhone simulator. Prefers a standard
# "iPhone <number> Pro" model (the reference device of the UI tests and accessibility
# audits) on the newest runtime, so results do not depend on new device form factors;
# falls back to any iPhone. Used by CI so the workflow does not depend on a device name.
set -euo pipefail

xcrun simctl list devices available --json | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, items in devices.items():
    if "iOS" not in runtime:
        continue
    version = tuple(int(p) for p in runtime.rsplit("iOS-", 1)[-1].split("-") if p.isdigit())
    for d in items:
        if d.get("isAvailable") and d["name"].startswith("iPhone"):
            standard_pro = re.fullmatch(r"iPhone \d+ Pro", d["name"]) is not None
            key = (standard_pro, version, d["name"])
            if best is None or key > best[0]:
                best = (key, d["udid"])
if best is None:
    sys.exit("No available iPhone simulator")
print(best[1])
'
