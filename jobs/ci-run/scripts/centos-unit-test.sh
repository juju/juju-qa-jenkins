#!/bin/bash
# Designed to be included by JJB jobs and not run stand-alone.

# Want to exit on uncaught errors.
set -ex

# Delete test dirs older than 1 day (but don't error if we get perms denied
# for anything)
find /tmp/ \( -name "test-mgo*" \
    -o -name "juju-*" \) \
    -mtime +1 \
    -printf 'Cleaning up: %f\n' \
    -prune -execdir rm -fr {} + || true

export JUJU_GOMOD_MODE=${JUJU_GOMOD_MODE}
echo JUJU_GOMOD_MODE=${JUJU_GOMOD_MODE}

# This script assumes a clean workspace.
mkdir _build
tar xf ${JUJU_SRC_TARBALL} -C _build/
GOPATH=${WORKSPACE}/_build/
full_path=${GOPATH}/src/github.com/juju/juju

export GOPATH=${GOPATH}
export PATH=$GOPATH/bin:$PATH

if which mongod ; then
    export JUJU_MONGOD=$(which mongod)
else
    # Sometimes the snap store can give an error like
    #   error: cannot install "juju-db": cannot query the store for updates: got
    #   unexpected HTTP status code 503 via POST to
    #   "https://api.snapcraft.io/v2/snaps/refresh"
    # So we'll try twice if needed.
    sudo snap install juju-db || sudo snap install juju-db
    export JUJU_MONGOD=/snap/bin/juju-db.mongod
fi

# This will be used to generate reports for jenkins.
GO111MODULE=off go get github.com/tebeka/go2xunit

cd ${full_path}

go version
go test -mod=vendor -i ./...

set +e  # Will fail in reports generation if any errors occur
set -o pipefail  # Need to error for make, not tees' success.
# Seeing this failing on centos with go10.1 but not on amd64 go10.2, not sure
# why.
export IGNORE_VET_WARNINGS=yesplease
make test VERBOSE_CHECK=1 | tee ${WORKSPACE}/go-unittest.out
exit_code=$?
set +o pipefail
${GOPATH}/bin/go2xunit -fail -input ${WORKSPACE}/go-unittest.out -output ${WORKSPACE}/tests.xml
# Sometimes go2xunit doesn't exit non-zero when we would expect it to. Force
# this based on make result.
exit ${exit_code}
