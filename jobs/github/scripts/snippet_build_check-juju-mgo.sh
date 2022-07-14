# Snippet used for the build/check for juju/juju

# Fail if anything unexpected happens
set -eux
function mgocleanup {
    make stopdb
}

cd ${GOPATH}/src/github.com/juju/mgo

sudo DEBIAN_FRONTEND=noninteractive apt-get -y install daemontools libsasl2-dev

echo "starting db"
trap mgocleanup EXIT
make startdb

set -o pipefail  # Need to error for make, not tees' success.

go get -v -d -t ./...

set +e  # Will fail in reports gen if any errors occur
set -o pipefail  # Need to error for make, not tees' success.
go test -v -check.v ./ ./sstxn ./txn ./bson | tee ${WORKSPACE}/go-unittest.out
check_exit=$?
set +o pipefail
echo `date --rfc-3339=seconds` "ran go test"
