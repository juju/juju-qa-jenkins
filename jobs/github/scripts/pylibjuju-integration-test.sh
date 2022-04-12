#!/bin/bash
set -ex

PY_VERSION=$(echo "${PYTHON_VERSION}" | sed 's/\.//g' | xargs -I% echo "py%")
MAINLINE_PYTHON_VERSION=$(echo "${PYTHON_VERSION}" | sed 's/3.5/3/g')

echo "Using python version ${PY_VERSION}."

# we need to force this, because juju will error out about the fact that it
# doesn't have permission to read the folder, even though there isn't anything
# in the folder.
sudo mkdir -p ~/.config
sudo chown -R $USER:$USER ~/.config
sudo chmod -R 755 ~/.config
sudo ls -l -R ~/.config

# Remove the existing lxd/lxd-client so we can install the snap version
# TODO (stickupkid): when we move away from xenial as the base series, we can
# probably skip this removal part.
sudo add-apt-repository ppa:deadsnakes/ppa
sudo apt-get update -q
sudo apt-get remove -qy --purge lxd lxd-client
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git make "python${PYTHON_VERSION}" "python${MAINLINE_PYTHON_VERSION}-distutils" "python3-pip"

PYTHON_PATH=$(which "python${PYTHON_VERSION}")
$PYTHON_PATH -m pip install --user tox

attempts=0
while [ $attempts -lt 3 ]; do
    sudo snap install lxd && break || true
    attempts=$((attempts + 1))
done
export PATH="/snap/bin:$PATH"

lxd waitready --timeout 120
sudo chmod 666 /var/snap/lxd/common/lxd/unix.socket
lxd init --auto --network-address='[::]' --network-port=8443 --storage-backend=dir
lxc network set lxdbr0 ipv6.address none

lxc storage create juju-zfs dir source=/var/snap/lxd/common/lxd/storage-pools/juju-zfs
lxc storage create juju-btrfs dir source=/var/snap/lxd/common/lxd/storage-pools/juju-btrfs

# TODO (stickupkid): we should be able to use security.priviledged="true",
# but for some reason that doesn't work in 2 nested deep containers. So
# instead we turn apparmor off, we should investigate why this doesn't work
# correctly.
lxc profile set default raw.lxc lxc.apparmor.profile=unconfined

attempts=0
while [ $attempts -lt 3 ]; do
    sudo snap install juju --channel "${JUJU_CHANNEL}" --classic && break || true
    attempts=$((attempts + 1))
done

juju bootstrap localhost test \
    --config 'identity-url=https://api.staging.jujucharms.com/identity' \
    --config 'allow-model-access=true' \
    --config 'test-mode=true'

cd ${dest_dir}

$PYTHON_PATH -m tox -e ${PY_VERSION} -e integration,serial
check_exit=$?
