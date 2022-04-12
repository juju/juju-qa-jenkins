    set -eux
    sudo apt-get -y update
    sudo apt-get -y --no-install-recommends install squashfuse build-essential devscripts equivs

    cd ${full_path}
    # when running inside a privileged container, snapd fails because udevd isn't
    # running, but on the second occurance it is.
    # see: https://github.com/lxc/lxd/issues/4308
    attempts=0
    while [ $attempts -lt 3 ]; do
        if [ ! "$(which go >/dev/null 2>&1)" ]; then
            make install-dependencies || true
            sleep 1
        fi
        attempts=$((attempts + 1))
    done

    echo GIT_COMMIT=${GIT_COMMIT}
    echo JUJU_BUILD_NUMBER=${JUJU_BUILD_NUMBER}
    echo JUJU_GOMOD_MODE=${JUJU_GOMOD_MODE}

    # Not release-install as the source already has patches applied.
    if [ -z "${BUILD_TAGS:-}" ]; then
        make install GIT_COMMIT="${GIT_COMMIT}" JUJU_BUILD_NUMBER="${JUJU_BUILD_NUMBER}" JUJU_GOMOD_MODE="${JUJU_GOMOD_MODE}"
    else
        echo BUILD_TAGS=${BUILD_TAGS}
        make install BUILD_TAGS="${BUILD_TAGS}" GIT_COMMIT="${GIT_COMMIT}" JUJU_BUILD_NUMBER="${JUJU_BUILD_NUMBER}" JUJU_GOMOD_MODE="${JUJU_GOMOD_MODE}"
    fi

    # Copy results for the caller job to collect.
    cp ${GOPATH}/bin/juju ${stash_dir}
    cp ${GOPATH}/bin/jujud ${stash_dir}
    cp ${GOPATH}/bin/jujuc ${stash_dir}
    cp ${GOPATH}/bin/juju-metadata ${stash_dir}

    # The k8sagent binary has been renamed to containeragent but we want to
    # retain the copy step until all branches have been properly updated.
    [ -f ${GOPATH}/bin/k8sagent ] && cp ${GOPATH}/bin/k8sagent ${stash_dir} || true
    [ -f ${GOPATH}/bin/containeragent ] && cp ${GOPATH}/bin/containeragent ${stash_dir} || true
    
    # 2.9+ uses the real pebble
    [ -f ${GOPATH}/bin/juju-fake-init ] && cp ${GOPATH}/bin/juju-fake-init ${stash_dir} || true
    [ -f ${GOPATH}/bin/pebble ] && cp ${GOPATH}/bin/pebble ${stash_dir} || true

    [ -f ${GOPATH}/bin/juju-wait-for ] && cp ${GOPATH}/bin/juju-wait-for ${stash_dir} || true
