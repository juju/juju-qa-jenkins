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

    if [ -f go.mod ]; then
        go mod download
    fi

    echo `date --rfc-3339=seconds` "building for release"
    make release-build
    # 2.4 patch removal fails so separate install to get the binary to test it.
    make install

    # Ensure the docs generation hasn't broken
    # gopath bin is guaranteed to be in $PATH
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3
    export PATH=$GOPATH/bin:$PATH
    echo "Using $(which juju) for docs check."
    ./scripts/generate-docs.py man -o /tmp/juju.1 || echo "ERROR: Docs generation failed."

    set +e  # Will fail in reports gen if any errors occur
    set -o pipefail  # Need to error for make, not tees' success.
    make check VERBOSE_CHECK=1 | tee ${WORKSPACE}/go-unittest.out
    check_exit=$?
    set +o pipefail
    echo `date --rfc-3339=seconds` "ran make check"

