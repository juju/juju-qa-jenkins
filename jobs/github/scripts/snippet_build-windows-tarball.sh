    set -e

    # ensure that we install the dependencies of juju for the unit tests below.
    jujusrc=${GOPATH}/src/github.com/juju/juju
    cd $jujusrc

    # when running inside a privileged container, snapd fails because udevd isn't
    # running, but on the second occurance it is.
    # see: https://github.com/lxc/lxd/issues/4308
    make install-dependencies || make install-dependencies
    make vendor-dependencies

    tarfile="raw-juju-source-vendor.tar.xz"
    tar cfz ${HOME}/$tarfile -C ${GOPATH} .
    check_exit=$?
