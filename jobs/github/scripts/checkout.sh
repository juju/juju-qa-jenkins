#!/bin/bash
set -ex

# Expected to be used within a ci-run job, but can be run stand alone.
# Needs the following env-vars set:
# $dest_dir: Destination to pull to, i.e. /home/user/go/src/github.com/juju/juju
# $repo: the repo to build, i.e. juju/juju
# $pr_id: the PR number to build, i.e. 9043
# $pr_commit: the commit sha of the pr to checkout, i.e. b66d8932d504d01a1ecebe0355afa7efe96cd45c
# $target_branch: the target branch of the PR, to merge into. i.e. develop

if [ -z "$dest_dir" ]; then
    echo "No \$dest_dir set, unable to continue."
    exit 1
fi

mkdir -p "$dest_dir"
tmpname=$(mktemp /tmp/pr.XXXXX)

mergeable_state="unknown"
retries=0
while [ "$mergeable_state" = "unknown" ]; do
    curl -s "https://api.github.com/repos/$repo/pulls/$pr_id" > "$tmpname"
    if [ -f "$tmpname" ]; then
        mergeable_state=$(jq -r ".\"mergeable_state\"" "$tmpname")
    fi

    # If the mergeable state is null, then handle that and ensure the mergeable
    # state is set back to unknown.
    if [ "$mergeable_state" = "null" ]; then
        mergeable_state="unknown"
    fi

    if [ "$mergeable_state" = "draft" ];  then
        echo "PR $pr_id is in a draft state"
        exit 1
    fi

    if [ "$mergeable_state" = "unknown" ]; then
        retries=$((retries+1))
        if [ $retries -gt 10 ]; then
            echo "https://github.com/$repo/pull/$pr_id failed to compute merge"
            exit 1
        fi
        echo `date --rfc-3339=seconds` "Waiting for GitHub to compute merge"
        sleep 10
    fi
done

mergeable=$(jq -r ".\"mergeable\"" "$tmpname")
if [ "$mergeable" != "true" ]; then
    echo "https://github.com/$repo/pull/$pr_id has merge conflicts"
    exit 1
fi

merge_commit=$(jq -r ".\"merge_commit_sha\"" "$tmpname")

git init "$dest_dir"
echo `date --rfc-3339=seconds` "Fetching branch"

cd "$dest_dir"

git remote add origin "https://github.com/$repo.git"
git config --local gc.auto 0
git fetch --no-tags --prune --progress --no-recurse-submodules --depth=1 origin "+$merge_commit"":refs/remotes/pull/$pr_id/merge"
git checkout --progress --force "refs/remotes/pull/$pr_id/merge"
git --no-pager log -1

echo `date --rfc-3339=seconds` "Fetched pseduo merge commit $merge_commit"
exit 0
