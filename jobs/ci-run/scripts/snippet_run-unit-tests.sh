#!/bin/bash
set -eux

# Make sure github is known to us.
ssh-keyscan github.com >> $HOME/.ssh/known_hosts

# Set path for bionic, if running in bionic
release=$(lsb_release -c -s)
if [[ $release == 'bionic' ]]; then
    export JUJU_MONGOD=/usr/bin/mongod
else
    export JUJU_MONGOD=/usr/lib/juju/mongo3.2/bin/mongod
fi

echo TEST_TIMEOUT=$TEST_TIMEOUT

cd ${{JUJU_SRC_PATH}}
# when running inside a privileged container, snapd fails because udevd isn't
# running, but on the second occurance it is.
# see: https://github.com/lxc/lxd/issues/4308  
make install-mongo-dependencies
make setup-lxd || true

# Disable JS support as juju-mongodb doesn't support it.
export JUJU_NOTEST_MONGOJS=1

if [[ "{GOTEST_TYPE}" == "race" ]]; then
    go test -v -race -test.timeout=${{TEST_TIMEOUT}} ./... | tee ${{WORKSPACE}}/go-unittest.out
    exit_code=$?
    ${{GOPATH}}/bin/go2xunit -fail -input ${{WORKSPACE}}/go-unittest.out -output ${{WORKSPACE}}/tests.xml
elif [[ "{GOTEST_TYPE}" == "xunit-report" ]]; then
    set +e  # Will fail in reports gen if any errors occur
    set -o pipefail  # Need to error for make, not tees' success.
    JUJU_GOMOD_MODE=vendor make test VERBOSE_CHECK=1 JUJU_SKIP_DEP=true TEST_TIMEOUT=${{TEST_TIMEOUT}} | tee ${{WORKSPACE}}/go-unittest.out
    exit_code=$?
    set +o pipefail
    ${{GOPATH}}/bin/go2xunit -fail -input ${{WORKSPACE}}/go-unittest.out -output ${{WORKSPACE}}/tests.xml
    # Sometimes go2xunit doesn't exit non-zero when we would expect it to. Force
    # this based on make result.
    exit $exit_code
else
    JUJU_GOMOD_MODE=vendor make test
fi

# Make sure we exit with the right error code and that it's not overwritten by anything.
exit $?
