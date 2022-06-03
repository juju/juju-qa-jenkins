    cd ${GOPATH}/src/${PROJECT_DIR}

    NEEDS_MGO=$(echo "${NEEDS_MGO}" | tr '[:upper:]' '[:lower:]')
    if [ "${NEEDS_MGO}" = "true" ]; then
      action=$(snap info juju-db | grep -q "installed" || echo "install")
      if [ "$action" == "" ]; then
              action="refresh"
      fi

      # when running inside a privileged container, snapd fails because udevd isn't
      # running, but on the second occurance it is.
      # see: https://github.com/lxc/lxd/issues/4308
      for i in {1..3}; do
        echo $action"ing juju-db snap. Attempt ""$i"
        sudo snap install juju-db --channel=4.4 && echo "Installed:" && which juju-db.mongo && juju-db.mongo --version && break || sleep 10
      done
    fi
    if [ ! -z "${EXTRA_PACKAGES}" ]; then
      echo "Installing packages ${EXTRA_PACKAGES}"
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $(echo ${EXTRA_PACKAGES} | sed "s/,/ /g")
    fi
    if [ ! -z "${EXTRA_SCRIPT}" ]; then
      eval ${EXTRA_SCRIPT}
    fi

    goversion=1.17
    if [ -f "go.mod" ]; then
      goversion=$(cat go.mod | grep "go 1." | sed 's/^go 1\.\(.*\)$/1.\1/')
    fi

    # when running inside a privileged container, snapd fails because udevd isn't
    # running, but on the second occurance it is.
    # see: https://github.com/lxc/lxd/issues/4308
    sudo snap refresh go --channel=${goversion}/stable --classic 2> /dev/null || sudo snap install go --channel=${goversion}/stable --classic

    if [ -f Makefile ]; then
      make check
    else
      set +e -o pipefail # don't exit immediately, let go2xunit find failures, but do record if go test fails
      go test -v ./... --check.v | tee ${WORKSPACE}/go-unittest.out
    fi
    check_exit=$?

