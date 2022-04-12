#!/bin/bash
set -ex

# Expected to be used within a ci-run job, but can be run stand alone.
# Needs the following env-vars set:
# $repo: the repo to build, i.e. juju/juju
# $pr_id: the PR number to build, i.e. 9043

tmpname=$(mktemp /tmp/pr.XXXXX)

mergeable_state="unknown"
retries=0
while [ "$mergeable_state" = "unknown" ]; do
    curl -s "https://api.github.com/repos/$ghprbGhRepository/pulls/$ghprbPullId" > "$tmpname"
    if [ -f "$tmpname" ]; then
        mergeable_state=$(jq -r ".\"mergeable_state\"" "$tmpname")
    fi
    
    # If the mergeable state is null, then handle that and ensure the mergeable
    # state is set back to unknown.
    if [ "$mergeable_state" = "null" ]; then
        mergeable_state="unknown"
    fi

    if [ "$mergeable_state" = "draft" ];  then
        echo "PR $ghprbPullId is in a draft state"
        exit 1
    fi

    if [ "$mergeable_state" = "unknown" ]; then
        retries=$((retries+1))
        if [ $retries -gt 10 ]; then
            echo "https://github.com/$ghprbGhRepository/pull/$ghprbPullId failed to compute merge"
            exit 1
        fi
        echo `date --rfc-3339=seconds` "Waiting for GitHub to compute merge"
        sleep 10
    fi
done

mergeable=$(jq -r ".\"mergeable\"" "$tmpname")
if [ "$mergeable" != "true" ]; then
    echo "https://github.com/$ghprbGhRepository/pull/$ghprbPullId has merge conflicts"
    exit 1
fi

merge_commit=$(jq -r ".\"merge_commit_sha\"" "$tmpname")

gomod=$(curl -s "https://raw.githubusercontent.com/$ghprbGhRepository/$merge_commit/go.mod")
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
