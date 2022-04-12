    # Snippet used for the build/check for juju/juju

    # Fail if anything unexpected happens
    set -eux
    function mgocleanup {
        make stopdb
    }

    # work around make lxd-setup creating a ~/.config owned by root
    mkdir -p ${HOME}/.config
    cd ${GOPATH}/src/github.com/juju/mgo
    git checkout v2

    goversion=$(cat go.mod | grep "go 1." | sed 's/^go 1\.\(.*\)$/1.\1/')

    # when running inside a privileged container, snapd fails because udevd isn't
    # running, but on the second occurance it is.
    # see: https://github.com/lxc/lxd/issues/4308
    sudo snap install go --channel=${goversion} --classic || sudo snap install go --channel=${goversion} --classic
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y install daemontools mongodb-clients libsasl2-dev 
    # Find the right package for various Ubuntu versions
    PKG_LIST=(
        mongodb-server-core
        juju-mongodb3.2
    )
    # juju-mongodb is available on Xenial if we want to test against it outside
    # of a Trusty environment.
    #    juju-mongodb
    for pkg in ${PKG_LIST[@]}; do
        if [[ ! -z `apt-cache search --names-only "^$pkg\$"` ]] ; then 
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $pkg
            break
        fi
    done
    export PATH="/usr/lib/juju/mongo3.2/bin:/usr/lib/juju/bin:$PATH"

    echo "starting db"
    trap mgocleanup EXIT
    make startdb

    set -o pipefail  # Need to error for make, not tees' success.

    go get -v -d -t ./...
    set +e # we don't want to fail here based on the tests, because then the xunit won't be generated
    (go test -v -fast -check.v ; (cd bson; go test -v -check.v); (cd txn; go test -v -fast -check.v))| tee ${WORKSPACE}/go-unittest.out
    # the wrapping script will use 'check_exit' to determine if the overall test run failed
    check_exit=$?
