# Snippet used for the build/check for juju/juju

# Fail if anything unexpected happens
set -e

function wait_for_dpkg() {
    # Just in case, wait for cloud-init.
    cloud-init status --wait 2> /dev/null || true
    while sudo lsof /var/lib/dpkg/lock-frontend 2> /dev/null; do
        echo "Waiting for dpkg lock..."
        sleep 10
    done
    while sudo lsof /var/lib/apt/lists/lock 2> /dev/null; do
        echo "Waiting for apt lock..."
        sleep 10
    done
}

# work around make lxd-setup creating a ~/.config owned by root
mkdir -p ${HOME}/.config
cd ${GOPATH}/src/github.com/juju/juju

echo `date --rfc-3339=seconds` "installing dependencies"
# when running inside a privileged container, snapd fails because udevd isn't
# running, but on the second occurance it is.
# see: https://github.com/lxc/lxd/issues/4308
wait_for_dpkg
make install-dependencies || make install-dependencies
make setup-lxd || true

echo `date --rfc-3339=seconds` "building for release"
make release-build
# 2.4 patch removal fails so separate install to get the binary to test it.
make install
check_exit=$?
echo `date --rfc-3339=seconds` "ran make install"