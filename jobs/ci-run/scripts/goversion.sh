#!/bin/bash
set -ex

gomod=$(curl -s "https://raw.githubusercontent.com/juju/juju/$GIT_COMMIT/go.mod")
goversion=$(echo "$gomod" | grep "go 1." | sed 's/^go 1\.\(.*\)$/1.\1/')

if [[ "$goversion" < "1.14" ]]; then
    echo "GOVERSION=$goversion is not valid"
    exit 1
elif [[ "$goversion" > "1.99" ]]; then
    echo "GOVERSION=$goversion is not valid"
    exit 1
fi

echo "GOVERSION=$goversion" > "${WORKSPACE}/goversion"

cat "${WORKSPACE}/goversion"
exit 0
