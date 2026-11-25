#!/bin/bash
set +x
set -eu

if ! command -v yq >/dev/null; then
  sudo snap install yq
fi
creds="$CLOUD_CITY/credentials.yaml"
client=$(yq '.credentials.azure.credentials.application-id' "$creds")
password=$(yq '.credentials.azure.credentials.application-password' "$creds")
az login --service-principal -u "$client" -p "$password" --tenant "$AZURE_TENANT" --output none
