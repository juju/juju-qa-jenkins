#!/bin/bash
set +x
set -euo pipefail

qa=2eebf55a-1e02-45d8-a299-02aed8aea00b
report=false
case "$#:${1:-}" in
  0:) ;;
  1:--report-qa) report=true ;;
  *) echo 'Usage: azure-cleanup.sh [--report-qa]' >&2; exit 2 ;;
esac

# Reject empty or multiple JSON documents, even if the CLI returned success.
read_az() {
  local response
  response=$(az "$@" --output json) || return
  jq -ces 'if length == 1 then .[0] else error("incomplete response") end' <<< "$response"
}

group_names() {
  jq -r --arg sub "$1" --arg region "$2" '
    def expected_id: "/subscriptions/" + $sub + "/resourceGroups/" + .name;
    if type != "array" or any(.[]; (.name | test("^[\\w().-]{1,90}\\z") | not) or
        (.id | ascii_downcase) != (expected_id | ascii_downcase)) or
        (map(.name | ascii_downcase) | unique | length) != length
    then error("unexpected group inventory") else .[] end |
    select((.id | contains("juju-")) and ($region == "" or (.location | ascii_downcase) == $region)) | .name'
}

oldest_resource() {
  local sub=$1 group=$2 region=$3
  read_az resource list --subscription "$sub" --resource-group "$group" |
    jq -r --arg prefix "/subscriptions/$sub/resourceGroups/$group/providers/" --arg region "$region" '
      def epoch:
        if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|\\+00:00)\\z")
        then .[:19] + "Z" else error("invalid creation time") end |
        . as $stamp | fromdate | if todate == $stamp then . else error("invalid date") end;
      if type != "array" or any(.[]; (.id | ascii_downcase | startswith($prefix | ascii_downcase) | not))
        then error("unexpected resource inventory")
      elif $region != "" and any(.[]; (has("createdTime") | not) or (.location | ascii_downcase) != $region)
        then null
      else map(.createdTime | select(. != null) | epoch) | min end'
}

old_enough() {
  [[ $1 != null ]] && (( ($2 - $1) / 3600 > 3 ))
}

clean_subscription() {
  local sub=$1 region=${2:-} groups group oldest current now
  local candidates=()
  read_az account show --subscription "$sub" | jq -e --arg sub "$sub" \
    '(.id | ascii_downcase) == ($sub | ascii_downcase) and .state == "Enabled"' >/dev/null
  groups=$(read_az group list --subscription "$sub" | group_names "$sub" "$region")
  # Finish discovery before deleting anything in this subscription.
  while IFS= read -r group; do
    [[ -n $group ]] || continue
    oldest=$(oldest_resource "$sub" "$group" "$region")
    now=$(date -u +%s)
    if old_enough "$oldest" "$now"; then
      candidates+=("$group")
    fi
  done <<< "$groups"

  for group in "${candidates[@]}"; do
    if "$report"; then
      echo "would delete $sub/$group"
      continue
    fi
    if [[ -n $region ]]; then
      current=$(read_az group show --subscription "$sub" --resource-group "$group" | jq -c '[.]' | group_names "$sub" "$region")
      [[ $current == "$group" ]] || continue
      oldest=$(oldest_resource "$sub" "$group" "$region")
      now=$(date -u +%s)
      old_enough "$oldest" "$now" || continue
    fi
    echo "deleting $sub/$group"
    az group delete --subscription "$sub" --resource-group "$group" \
      -f Microsoft.Compute/virtualMachineScaleSets -f Microsoft.Compute/virtualMachines -y
  done
}

if ! "$report"; then
  for tool in jq yq; do
    command -v "$tool" >/dev/null || sudo snap install "$tool"
  done
  creds="$CLOUD_CITY/credentials.yaml"
  legacy=$(yq -er '.credentials.azure.credentials.subscription-id' < "$creds")
  if [[ ! $legacy =~ ^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$ || ${legacy,,} == "$qa" ]]; then
    echo 'Unsafe legacy subscription' >&2; exit 1
  fi
  client=$(yq -er '.credentials.azure.credentials.application-id' < "$creds")
  password=$(yq -er '.credentials.azure.credentials.application-password' < "$creds")
  if ! az login --service-principal -u "$client" -p "$password" --tenant "$AZURE_TENANT" --output none >/dev/null 2>&1; then
    echo 'Azure service-principal login failed' >&2; exit 1
  fi
  unset client password
  clean_subscription "$legacy"
fi
clean_subscription "$qa" eastus
