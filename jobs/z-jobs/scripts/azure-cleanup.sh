#!/bin/bash
set -eux

if [ ! "$(which jq >/dev/null 2>&1)" ]; then
  sudo snap install jq || true
fi
if [ ! "$(which yq >/dev/null 2>&1)" ]; then
  sudo snap install yq || true
fi

az login --service-principal \
  -u "$(cat "$CLOUD_CITY"/credentials.yaml | yq ".credentials.azure.credentials.application-id")" \
  -p "$(cat "$CLOUD_CITY"/credentials.yaml | yq ".credentials.azure.credentials.application-password")" \
  --tenant "$AZURE_TENANT"

HOURS=3
subscription_id=$(cat "$CLOUD_CITY"/credentials.yaml | yq ".credentials.azure.credentials.subscription-id")
echo "cleaning subscription $subscription_id"
az group list --subscription "$subscription_id" | jq -r '.[] | select(.id | contains("juju-")) | .name' | while read group ; do
  oldest=$(az resource list --subscription "$subscription_id" --resource-group "$group" | jq -r 'map(select(.createdTime != null)) | map(.createdTime | split(".") | (.[0] + "Z") | fromdate) | sort | .[0]')
  if [[ "$oldest" = "null" ]]; then
    echo "skipping $group"
    continue
  fi
  if [ $((($(date -u +%s)-$oldest)/3600)) -gt $HOURS ]; then
    echo "deleting resource group $group"
    az group delete --subscription "$subscription_id" --resource-group "$group" -f "Microsoft.Compute/virtualMachineScaleSets" -f "Microsoft.Compute/virtualMachines" -y
  fi
done
