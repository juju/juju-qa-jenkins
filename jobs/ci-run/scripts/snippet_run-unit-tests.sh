    export PATH=${{GOPATH}}/bin:$PATH:/snap/bin

    # Make sure github is known to us.
    ssh-keyscan github.com >> $HOME/.ssh/known_hosts

    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y make gcc squashfuse

    # Delete test dirs older than 1 day (but don't error if we get perms denied for anything)
    find /tmp/ \( -name "test-mgo*" \
      -o -name "juju-*" \) \
      -mmin +180 \
      -printf 'Cleaning up: %f\n' \
      -prune -execdir rm -fr {{}} + || true

    # Set path for bionic, if running in bionic
    release=$(lsb_release -c -s)
    if [[ $release == 'bionic' ]]; then
        export JUJU_MONGOD=/usr/bin/mongod
    else
        export JUJU_MONGOD=/usr/lib/juju/mongo3.2/bin/mongod
    fi

    export JUJU_GOMOD_MODE={JUJU_GOMOD_MODE}
    echo JUJU_GOMOD_MODE=$JUJU_GOMOD_MODE
    source ${{WORKSPACE}}/build.properties
    echo TEST_TIMEOUT=$TEST_TIMEOUT

    cd ${{full_path}}
    # when running inside a privileged container, snapd fails because udevd isn't
    # running, but on the second occurance it is.
    # see: https://github.com/lxc/lxd/issues/4308  
    make install-dependencies || true
    make install-dependencies
    make setup-lxd || true

    # This will be used to generate reports for jenkins.
    GO111MODULE=off go get github.com/tebeka/go2xunit

    make build
    # Disable JS support as juju-mongodb doesn't support it.
    export JUJU_NOTEST_MONGOJS=1

    if [[ "{GOTEST_TYPE}" == "race" ]]; then
        go test -v -race -test.timeout=${{TEST_TIMEOUT}} ./... | tee ${{stash_dir}}/go-unittest.out
        exit_code=$?
        go2xunit -fail -input ${{stash_dir}}/go-unittest.out -output ${{stash_dir}}/tests.xml
    elif [[ "{GOTEST_TYPE}" == "xunit-report" ]]; then
        set +e  # Will fail in reports gen if any errors occur
        set -o pipefail  # Need to error for make, not tees' success.
        make test VERBOSE_CHECK=1 JUJU_SKIP_DEP=true TEST_TIMEOUT=${{TEST_TIMEOUT}} | tee ${{stash_dir}}/go-unittest.out
        exit_code=$?
        set +o pipefail
        go2xunit -fail -input ${{stash_dir}}/go-unittest.out -output ${{stash_dir}}/tests.xml
        # Sometimes go2xunit doesn't exit non-zero when we would expect it to. Force
        # this based on make result.
        exit $exit_code
    else
        make test
    fi

    # Make sure we exit with the right error code and that it's not overwritten by anything.
    exit $?
