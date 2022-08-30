#!/bin/bash
# shellcheck disable=SC2296

set -eux

# Term is set to "unknown" in jenkins, so we force it to empty. Ensuring it
# doesn't error out later on.
export TERM=""
export TEST_RUNNER_NAME="${{TEST_RUNNER_NAME}}"

if [ ! -d "$JUJU_SRC_PATH"/tests ]; then
    echo "Test directory not found."
    echo "Assuming pre tests setup found, exiting early."
    exit 0
fi

export PATH="${{BIN_DIR}}":$PATH

# Copy the juju cloud credentials to ~/.local/share/juju. This is
# required for bootstrapping non-lxd providers for the integration tests.
mkdir -p "$HOME"/.local/share/juju
sudo cp -R "$JUJU_DATA"/. "$HOME"/.local/share/juju
sudo chown -R "$USER" "$HOME"/.local/share/juju

while sudo lsof /var/lib/dpkg/lock-frontend 2> /dev/null; do
    echo "Waiting for dpkg lock..."
    sleep 10
done
while sudo lsof /var/lib/apt/lists/lock 2> /dev/null; do
    echo "Waiting for apt lock..."
    sleep 10
done
sudo apt-get -y update

# Issue around installing a snap within a privileged container on a host
# fails. There is no real work around once privileged and nesting has been
# set, so retries succeed.
attempts=0
while [ $attempts -lt 3 ]; do
    if [ ! "$(which jq >/dev/null 2>&1)" ]; then
        sudo snap install jq || true
    fi
    if [ ! "$(which yq >/dev/null 2>&1)" ]; then
        sudo snap install yq || true
    fi
    if [ ! "$(which shellcheck >/dev/null 2>&1)" ]; then
        sudo snap install shellcheck || true
    fi
    if [ ! "$(which expect >/dev/null 2>&1)" ]; then
        sudo snap install expect || true
    fi
    if [ ! "$(which petname >/dev/null 2>&1)" ]; then
        sudo snap install petname || true
    fi
    # shellcheck disable=SC2193
    if [ "${{BOOTSTRAP_PROVIDER:-}}" = "aws" ]; then
        if [ ! "$(which aws >/dev/null 2>&1)" ]; then
            sudo snap install aws-cli --classic || true
        fi

        mkdir -p "$HOME"/.aws
        echo "[default]" > "$HOME"/.aws/credentials
        cat "$HOME"/.local/share/juju/credentials.yaml |\
            grep aws: -A 4 | grep key: |\
            tail -2 |\
            sed -e 's/      access-key:/aws_access_key_id =/' \
                -e 's/      secret-key:/aws_secret_access_key =/' \
            >> "$HOME"/.aws/credentials
        echo -e "[default]\nregion = us-east-1" > "$HOME"/.aws/config
        chmod 600 ~/.aws/*
    fi
    attempts=$((attempts + 1))
done

cd "$JUJU_SRC_PATH"/tests

set +x
OUT=$(./main.sh -H 2>&1)
if [ "$(echo "$OUT" | grep -q "Illegal option -H" || true)" ]; then
    echo "Not supported runner query."
    exit 1
elif [ "$(echo "$OUT" | grep -q "${{TEST_RUNNER_NAME}}" || true)" ]; then
    echo "Test ${{TEST_RUNNER_NAME}} not found."
    echo "Recording as success."
    exit 0
fi
set -x

# Export any injected test-runner envvars so they can be picked up by main.sh
set +u
export BOOTSTRAP_PROVIDER
export BOOTSTRAP_CLOUD
export BOOTSTRAP_SERIES
export BOOTSTRAP_REUSE_LOCAL
export OPERATOR_IMAGE_ACCOUNT
# shellcheck source=/dev/null
set -u

echo "=> Running tests"

artifacts_dir="${{WORKSPACE}}/artifacts"
mkdir -p "$artifacts_dir"

set -o pipefail
./main.sh -v \
  -a "${{artifacts_dir}}"/output.tar.gz \
  -x output.txt \
  -s \""${{TEST_SKIP_TASKS:-}}"\" \
  "${{TEST_RUNNER_NAME}}" "${{TEST_TASK_NAME:-}}"  2>&1 | tee output.txt
exit_code=$?
set +o pipefail

exit $exit_code
