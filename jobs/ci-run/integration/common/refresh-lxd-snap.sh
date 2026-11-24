#!/bin/bash
# Refresh the LXD snap to the channel requested by the LXD_SNAP_CHANNEL
# job parameter before running LXD-backed integration tests.
set -eux

if [ "${BOOTSTRAP_PROVIDER:-}" != "lxd" ]; then
  echo "Not an LXD test job; leaving installed LXD snap unchanged"
  exit 0
fi

if [ -z "${JUJU_VERSION:-}" ]; then
  echo "JUJU_VERSION is not set; cannot decide whether to refresh LXD" >&2
  exit 1
fi

juju_major_minor="$(printf '%s' "${JUJU_VERSION}" | cut -d- -f1 | cut -d. -f1,2)"
if [ "${juju_major_minor}" = "2.9" ]; then
  echo "Juju ${JUJU_VERSION} is 2.9.x; leaving installed LXD snap unchanged"
  exit 0
fi

channel="${LXD_SNAP_CHANNEL:-}"
if [ -z "${channel}" ]; then
  echo "LXD_SNAP_CHANNEL is empty; leaving installed LXD snap unchanged"
  exit 0
fi

if [[ ! "${channel}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/(stable|candidate|beta|edge)(/[A-Za-z0-9][A-Za-z0-9._-]*)?$ ]]; then
  echo "Invalid LXD snap channel: ${channel}" >&2
  exit 2
fi

current=""
if snap list lxd >/dev/null 2>&1; then
  current="$(snap list lxd | awk 'NR==2 {print $4}')"
fi

if [ -z "${current}" ]; then
  echo "Installing LXD snap from channel ${channel}"
  sudo snap install lxd --channel="${channel}"
elif [ "${current}" = "${channel}" ]; then
  echo "LXD snap already tracks ${channel}; no refresh needed"
else
  echo "Refreshing LXD snap from ${current} to ${channel}"
  attempt=1
  while ! sudo snap refresh lxd --channel="${channel}"; do
    if [ "${attempt}" -ge 3 ]; then
      echo "Failed to refresh LXD snap after ${attempt} attempts" >&2
      exit 1
    fi
    attempt=$((attempt + 1))
    echo "Retrying LXD snap refresh (attempt ${attempt}/3)"
    sleep 15
  done
fi

actual="$(snap list lxd | awk 'NR==2 {print $4}')"
if [ "${actual}" != "${channel}" ]; then
  echo "LXD snap tracks ${actual}, expected ${channel}" >&2
  exit 1
fi

sudo lxd waitready --timeout=300
snap list lxd
lxd --version

# Keep the refreshed snap stable for the duration of the test run.
sudo snap refresh --hold lxd || true
