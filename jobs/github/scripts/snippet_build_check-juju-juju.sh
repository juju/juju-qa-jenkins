# Snippet used for the build/check for juju/juju

# Fail if anything unexpected happens
set -e

# work around make lxd-setup creating a ~/.config owned by root
mkdir -p ${HOME}/.config
export HOME=${HOME}
cd ${GOPATH}/src/github.com/juju/juju

echo `date --rfc-3339=seconds` "installing dependencies"
# when running inside a privileged container, snapd fails because udevd isn't
# running, but on the second occurance it is.
# see: https://github.com/lxc/lxd/issues/4308
make install-dependencies || make install-dependencies
make setup-lxd || true

if [ -d "./scripts/dqlite" ]; then
    echo `date --rfc-3339=seconds` "installing musl"
    sudo make MUSL_CROSS_COMPILE=0 musl-install dqlite-install || { echo "Failed to install musl"; exit 1; }
fi

if [ -f go.mod ]; then
    go mod download
fi

echo `date --rfc-3339=seconds` "checking build..."
make install

echo `date --rfc-3339=seconds` "running unit tests..."
set +e  # Will fail in reports gen if any errors occur
set -o pipefail  # Need to error for make, not tees' success.
if [ "$(make -q race-test > /dev/null 2>&1 || echo $?)" -eq 2 ]; then
    # if we don't have a race-test target, use go test.
    go test -v -race ./... | tee ${WORKSPACE}/go-unittest.out
    check_exit=$?
else
    make race-test VERBOSE_CHECK=1 JUJU_DEBUG=1 | tee ${WORKSPACE}/go-unittest.out
    check_exit=$?
fi
set +o pipefail
echo `date --rfc-3339=seconds` "ran make race-test"
