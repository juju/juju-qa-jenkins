#!/bin/bash
set -eux

juju_data="$HOME/.local/share/juju"
mkdir -p "$juju_data"
sudo cp -R "$JUJU_DATA/credentials.yaml" "$juju_data"
sudo chown -R "$USER" "$juju_data"

REGION="${REGION:-us-east-1}"

mkdir -p "$HOME"/.aws
echo "[default]" > "$HOME"/.aws/credentials
cat "$juju_data/credentials.yaml" |\
    grep aws: -A 4 | grep key: |\
    tail -2 |\
    sed -e 's/      access-key:/aws_access_key_id =/' \
        -e 's/      secret-key:/aws_secret_access_key =/' \
    >> "$HOME"/.aws/credentials
echo -e "[default]\nregion = ${REGION}" > "$HOME"/.aws/config
chmod 600 ~/.aws/*