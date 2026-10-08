#!/bin/bash
# shellcheck disable=SC2296

set -eux

# Term is set to "unknown" in jenkins, so we force it to empty. Ensuring it
# doesn't error out later on.
export TERM=""
export TEST_RUNNER_NAME="${TEST_RUNNER_NAME}"

if [ -z "${JUJU_SRC_PATH}" ]; then
  echo "Source path is not set."
  exit 1
fi

if [ ! -d "${JUJU_SRC_PATH}"/tests ]; then
    echo "Test directory not found."
    echo "Assuming pre tests setup found, exiting early."
    exit 0
fi

export PATH="${BIN_DIR}":$PATH

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
    if ! which charmcraft >/dev/null 2>&1; then
        sudo snap install charmcraft --classic || true
    fi
    if ! which jq >/dev/null 2>&1; then
        sudo snap install jq || true
    fi
    if ! which yq >/dev/null 2>&1; then
        sudo snap install yq || true
    fi
    if ! which shellcheck >/dev/null 2>&1; then
        sudo snap install shellcheck || true
    fi
    if ! which expect >/dev/null 2>&1; then
        sudo apt-get -y install expect || true
    fi
    if ! which petname >/dev/null 2>&1; then
        sudo snap install petname || true
    fi
    if ! which microceph >/dev/null 2>&1; then
        sudo snap install microceph || true
    fi
    if ! which gcloud >/dev/null 2>&1; then
        sudo snap install google-cloud-cli --classic || true
    fi
    attempts=$((attempts + 1))
done

# The 3.6 -> 4.x model migration suites bootstrap their source
# controllers with a juju 3.6 client. The runner image does not ship
# a juju_36 parallel instance, so enable snapd's parallel-instances
# option (takes effect immediately, no reboot needed) and install
# the juju snap as juju_36 from the 3.6/stable channel. The distinct
# instance name avoids any PATH ambiguity with the payload's built
# juju binary; the suites consume it via JUJU_MIGRATION_36_BIN.
if [[ ${TEST_RUNNER_NAME:-} == migration* ]]; then
    if [[ $(sudo snap get system experimental.parallel-instances 2>/dev/null) != true ]]; then
        sudo snap set system experimental.parallel-instances=true
    fi
    juju_36_attempts=0
    while ! snap list juju_36 2>/dev/null | grep -q '3\.6'; do
        if (( juju_36_attempts >= 3 )); then
            echo "Failed to install the juju 3.6 snap for the migration suites" >&2
            exit 1
        fi
        sudo snap install juju_36 --channel 3.6/stable || true
        juju_36_attempts=$((juju_36_attempts + 1))
    done
    export JUJU_MIGRATION_36_BIN=/snap/bin/juju_36
fi

cd "$JUJU_SRC_PATH"/tests

set +x
OUT=$(./main.sh -H 2>&1)
if [ "$(echo "$OUT" | grep -q "Illegal option -H" || true)" ]; then
    echo "Not supported runner query."
    exit 1
elif [ "$(echo "$OUT" | grep -q "${TEST_RUNNER_NAME}" || true)" ]; then
    echo "Test ${TEST_RUNNER_NAME} not found."
    echo "Recording as success."
    exit 0
fi
set -x

# Export any injected test-runner envvars so they can be picked up by main.sh
set +u
export BOOTSTRAP_PROVIDER
export BOOTSTRAP_CLOUD
export BOOTSTRAP_REUSE_LOCAL
export OPERATOR_IMAGE_ACCOUNT
# Snap based bootstrap (Juju 4.2+) uses the controller snap shipped in the
# build payload; test runners have no toolchain to build one. Unset for
# payloads without a snap (older branches) and for local runs, where
# bootstrap builds the snap from source itself.
CONTROLLER_SNAP_PATH=
for _snap in "${BIN_DIR}"/jujud_*.snap; do
  if [ -f "${_snap}" ]; then
    CONTROLLER_SNAP_PATH="${_snap}"
  fi
done
export CONTROLLER_SNAP_PATH
# shellcheck source=/dev/null
set -u

echo "=> Running tests"

artifacts_dir="${WORKSPACE}/artifacts"
mkdir -p "$artifacts_dir"

set -o pipefail
./main.sh -v \
  -a "${artifacts_dir}"/output.tar.gz \
  -x output.txt \
  -s \""${TEST_SKIP_TASKS:-}"\" \
  "${TEST_RUNNER_NAME}" "${TEST_TASK_NAME:-}"  2>&1 | tee output.txt
exit_code=$?
set +o pipefail

exit $exit_code
