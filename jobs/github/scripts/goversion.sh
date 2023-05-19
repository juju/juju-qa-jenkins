#!/bin/bash
set -ex

set +e
gomod=$(curl -fs "https://raw.githubusercontent.com/$ghprbGhRepository/$MERGE_COMMIT/go.mod")
rval=$?
if [ $rval -ne 0 ]; then
  echo "GOVERSION=''" > "${WORKSPACE}/goversion"
  exit 0
fi
set -e
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
