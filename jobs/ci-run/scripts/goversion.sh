#!/bin/bash
set -ex

GITHUB_REPO=${GITHUB_REPO:-juju/juju}

if [ -z "${GITHUB_TOKEN}" ]; then
gomod=$(curl -s "https://raw.githubusercontent.com/$GITHUB_REPO/$GIT_COMMIT/go.mod")
else
gomod=$(curl -s "https://api.github.com/repos/$GITHUB_REPO/contents/go.mod?ref=$GIT_COMMIT" --header "Authorization: Bearer $GITHUB_TOKEN" | jq ".content" -r | base64 -d)
fi
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
