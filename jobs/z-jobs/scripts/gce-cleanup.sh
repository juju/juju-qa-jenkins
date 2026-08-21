#!/bin/bash
set -euo pipefail

: "${SCRIPTS_DIR:?SCRIPTS_DIR must be set}"
: "${GCE_CREDENTIALS_FILE:?GCE_CREDENTIALS_FILE must be set}"

export GCE_PROJECT_ID="${GCE_PROJECT_ID:-gothic-list-89514}"

# Set this to false for a dry run.
DELETE_ORPHANED_FIREWALL_RULES="${DELETE_ORPHANED_FIREWALL_RULES:-true}"

# Display Juju instances and delete non-permanent instances older than 2 hours.
python3 "${SCRIPTS_DIR}/gce.py" -v list-instances 'juju-*'
python3 "${SCRIPTS_DIR}/gce.py" -v delete-instances -o 2 'juju-*'

gcloud auth activate-service-account \
    --key-file="${GCE_CREDENTIALS_FILE}"

gcloud config set project "${GCE_PROJECT_ID}"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

instances_file="${work_dir}/instances.json"
rules_file="${work_dir}/firewall-rules.json"
orphan_rules_file="${work_dir}/orphan-rules"

# Collect every remaining instance and its network tags.
#
# Do not limit this query to juju-* instance names: if any remaining instance
# uses a Juju firewall target tag, the corresponding rule must be retained.
gcloud compute instances list \
    --project="${GCE_PROJECT_ID}" \
    --format=json \
    > "${instances_file}"

# Only Juju-created firewall rules are candidates for cleanup.
gcloud compute firewall-rules list \
    --project="${GCE_PROJECT_ID}" \
    --filter="name~'^juju-'" \
    --format=json \
    > "${rules_file}"

# Find Juju firewall rules whose target tags are not used by any remaining
# instance. Rules without target tags are skipped because their ownership
# cannot be established safely.
python3 - \
    "${instances_file}" \
    "${rules_file}" \
    > "${orphan_rules_file}" <<'PY'
import json
import sys

instances_path, rules_path = sys.argv[1:3]

with open(instances_path, encoding="utf-8") as stream:
    instances = json.load(stream)

with open(rules_path, encoding="utf-8") as stream:
    rules = json.load(stream)

if not isinstance(instances, list):
    raise SystemExit("GCE instances response is not a JSON list")

if not isinstance(rules, list):
    raise SystemExit("GCE firewall response is not a JSON list")

active_tags = set()

for instance in instances:
    if not isinstance(instance, dict):
        raise SystemExit("Malformed instance entry in GCE response")

    instance_name = instance.get("name", "<unknown>")
    tags = instance.get("tags") or {}

    if not isinstance(tags, dict):
        raise SystemExit(
            f"Malformed tags for GCE instance {instance_name}"
        )

    tag_items = tags.get("items") or []

    if not isinstance(tag_items, list):
        raise SystemExit(
            f"Malformed tag list for GCE instance {instance_name}"
        )

    for tag in tag_items:
        if not isinstance(tag, str):
            raise SystemExit(
                f"Non-string network tag on GCE instance {instance_name}"
            )
        active_tags.add(tag)

for rule in rules:
    if not isinstance(rule, dict):
        raise SystemExit("Malformed firewall rule entry in GCE response")

    name = rule.get("name")

    if not isinstance(name, str) or not name.startswith("juju-"):
        continue

    target_tags = rule.get("targetTags") or []

    if not isinstance(target_tags, list):
        raise SystemExit(
            f"Malformed targetTags for firewall rule {name}"
        )

    if not target_tags:
        print(
            f"Skipping {name}: the rule has no target tags, so its "
            "ownership cannot be established safely",
            file=sys.stderr,
        )
        continue

    if not all(isinstance(tag, str) for tag in target_tags):
        raise SystemExit(
            f"Non-string target tag on firewall rule {name}"
        )

    # Retain the rule when at least one remaining instance uses one of its
    # target tags. Otherwise the rule is an orphan candidate.
    if active_tags.isdisjoint(target_tags):
        print(name)
PY

if [[ ! -s "${orphan_rules_file}" ]]; then
    echo "No orphaned Juju firewall rules found."
    exit 0
fi

echo "Orphaned Juju firewall rule candidates:"
while IFS= read -r rule; do
    [[ -n "${rule}" ]] || continue
    printf '  - %s\n' "${rule}"
done < "${orphan_rules_file}"

if [[ "${DELETE_ORPHANED_FIREWALL_RULES}" != "true" ]]; then
    echo "Dry run: no firewall rules were deleted."
    echo "Set DELETE_ORPHANED_FIREWALL_RULES=true to enable deletion."
    exit 0
fi

while IFS= read -r rule; do
    [[ -n "${rule}" ]] || continue

    printf 'Deleting orphaned firewall rule %s...\n' "${rule}"

    gcloud compute firewall-rules delete "${rule}" \
        --project="${GCE_PROJECT_ID}" \
        --quiet
done < "${orphan_rules_file}"

echo "Orphaned Juju firewall-rule cleanup completed."
