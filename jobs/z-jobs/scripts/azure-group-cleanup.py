#!/usr/bin/python3
"""Hourly janitor. --report-qa needs only a read-only Azure CLI session."""
import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from uuid import UUID

QA = "2eebf55a-1e02-45d8-a299-02aed8aea00b"
REGION = "eastus"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_az(sub, *args):
    return json.loads(subprocess.check_output(
        ["az", *args, "--subscription", sub, "--output", "json"]))


def group_name(group, sub):
    name = group["name"]
    require(re.fullmatch(r"[\w().-]{1,90}", name), "invalid group name")
    expected = f"/subscriptions/{sub}/resourceGroups/{name}"
    require(group["id"].lower() == expected.lower(), "unexpected group scope")
    return name


def location(row):
    value = row["location"]
    require(isinstance(value, str) and value.strip(), "missing location")
    return value.lower()


def eligible(group, sub):
    name = group_name(group, sub)
    if "juju-" not in group["id"] or (sub == QA and location(group) != REGION):
        return False
    rows = read_az(sub, "resource", "list", "--resource-group", name)
    require(isinstance(rows, list), "incomplete resource inventory")
    oldest = None
    mixed = False
    for row in rows:
        prefix = group["id"].lower() + "/providers/"
        require(row["id"].lower().startswith(prefix), "unexpected resource scope")
        if sub == QA and location(row) != REGION:
            mixed = True
        # Undated resources do not participate in the legacy age calculation.
        stamp = row["createdTime"] if sub == QA else row.get("createdTime")
        if stamp is not None:
            require(re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|\+00:00)", stamp),
                    "invalid UTC resource timestamp")
            created = datetime.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
            oldest = created if oldest is None else min(oldest, created)
    if mixed:
        print(f"retain {sub}/{name}: resource outside {REGION}")
    if not mixed and oldest is not None:
        return (datetime.now(timezone.utc) - oldest).total_seconds() // 3600 > 3
    return False


def clean(sub, report):
    account = read_az(sub, "account", "show")
    require(account["id"].lower() == sub.lower() and account["state"] == "Enabled",
            "unexpected or disabled subscription")
    groups = read_az(sub, "group", "list")
    require(isinstance(groups, list), "incomplete group inventory")
    # Finish discovery in this subscription before its first delete.
    names = [group_name(g, sub).lower() for g in groups]
    require(len(set(names)) == len(names), "duplicate group")
    candidates = [g["name"] for g in groups if eligible(g, sub)]
    print(f"{sub}: {len(groups)} groups, {len(candidates)} candidates")
    for name in candidates:
        if report:
            print(f"would delete {sub}/{name}")
            continue
        if sub == QA:
            current = read_az(sub, "group", "show", "--resource-group", name)
            require(group_name(current, sub) == name, "group changed during discovery")
            if not eligible(current, sub):
                continue
        print(f"deleting {sub}/{name}", flush=True)
        subprocess.run(["az", "group", "delete", "--subscription", sub, "--resource-group", name,
                        "-f", "Microsoft.Compute/virtualMachineScaleSets",
                        "-f", "Microsoft.Compute/virtualMachines", "-y"], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report-qa", action="store_true")
    args = parser.parse_args()
    if not args.report_qa:
        sub = subprocess.check_output(["yq", ".credentials.azure.credentials.subscription-id",
                                       Path(os.environ["CLOUD_CITY"]) / "credentials.yaml"], text=True).strip()
        require(str(UUID(sub)) == sub.lower() and sub.lower() != QA, "unsafe legacy subscription")
        clean(sub, False)
    clean(QA, args.report_qa)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, TypeError, AttributeError, KeyError, OSError, subprocess.CalledProcessError) as exc:
        sys.exit(f"Azure cleanup stopped: {type(exc).__name__}; check access and inventory scope")
