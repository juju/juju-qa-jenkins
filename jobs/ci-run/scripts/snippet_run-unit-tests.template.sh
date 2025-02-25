#!/bin/bash
set -eux

# Make sure github is known to us.
ssh-keyscan github.com >> $HOME/.ssh/known_hosts

echo TEST_TIMEOUT=$TEST_TIMEOUT

cd ${{JUJU_SRC_PATH}}
# when running inside a privileged container, snapd fails because udevd isn't
# running, but on the second occurance it is.
# see: https://github.com/lxc/lxd/issues/4308  
make install-mongo-dependencies
make setup-lxd || true

# Disable JS support as juju-mongodb doesn't support it.
export JUJU_NOTEST_MONGOJS=1

set +e  # Will fail in reports gen if any errors occur
set -o pipefail  # Need to error for make, not tees' success.
if [[ "{GOTEST_TYPE}" == "race" ]]; then
    if [ "$(make -q race-test > /dev/null 2>&1 || echo $?)" -eq 2 ]; then
        # if we don't have a race-test target, use go test.
        go test -v -race -test.timeout=${{TEST_TIMEOUT}} ./... | tee ${{WORKSPACE}}/go-unittest.out
        exit_code=$?
    else
        JUJU_GOMOD_MODE=vendor make race-test VERBOSE_CHECK=1 TEST_TIMEOUT=${{TEST_TIMEOUT}} | tee ${{WORKSPACE}}/go-unittest.out
        exit_code=$?
    fi
elif [[ "{GOTEST_TYPE}" == "xunit-report" ]]; then
    JUJU_GOMOD_MODE=vendor make test VERBOSE_CHECK=1 FUZZ_CHECK={FUZZ_CHECK} TEST_TIMEOUT=${{TEST_TIMEOUT}} | tee ${{WORKSPACE}}/go-unittest.out
    exit_code=$?
fi
set +o pipefail

${{GOPATH}}/bin/go2xunit -fail -input ${{WORKSPACE}}/go-unittest.out -output ${{WORKSPACE}}/tests.xml
# Sometimes go2xunit doesn't exit non-zero when we would expect it to. Force
# this based on make result.
exit $exit_code
