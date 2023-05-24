#!/bin/bash
set -ex

# Expected to be used within a ci-run job, but can be run stand alone.
# Needs the following env-vars set:
# $dest_dir: Destination to pull to, i.e. /home/user/go/src/github.com/juju/juju
# $ghprbGhRepository: the repo to build, i.e. juju/juju
# $ghprbPullId: the PR number to build, i.e. 9043
# $pr_commit: the commit sha of the pr to checkout, i.e. b66d8932d504d01a1ecebe0355afa7efe96cd45c
# $target_branch: the target branch of the PR, to merge into. i.e. develop

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

echo "MERGE_COMMIT=$merge_commit" > "${WORKSPACE}/merge-commit"

cat "${WORKSPACE}/merge-commit"
exit 0
