#!/bin/bash
set -xe

echo "GITHUB_REPO=$GITHUB_REPO"
echo "GITHUB_BRANCH_NAME=$GITHUB_BRANCH_NAME"
echo "GITHUB_BRANCH_HEAD_SHA=$GITHUB_BRANCH_HEAD_SHA"
echo "GIT_COMMIT=$GIT_COMMIT"
echo "SHORT_GIT_COMMIT=$SHORT_GIT_COMMIT"

TMP_CLONE=$(mktemp -d -u)

function cleanup {
    rm -Rf "$TMP_CLONE"
}

trap cleanup EXIT

function query_github_simple { \
    curl -s "https://api.github.com/repos/$GITHUB_REPO/commits/$1" --header "Authorization: Bearer $GITHUB_TOKEN" --header "X-GitHub-Api-Version: 2022-11-28" | jq -r ".sha // empty"
}

function query_github_treeish {
    curl -s "https://api.github.com/repos/$GITHUB_REPO/git/trees/$1" --header "Authorization: Bearer $GITHUB_TOKEN" --header "X-GitHub-Api-Version: 2022-11-28" | jq -r ".sha // empty"
}

function search_github_hash {
    curl -s -H "Accept: application/vnd.github.cloak-preview+json" "https://api.github.com/search/commits?q=repo:$GITHUB_REPO+hash:$1" --header "Authorization: Bearer $GITHUB_TOKEN" --header "X-GitHub-Api-Version: 2022-11-28" | jq -r ".items[0].sha // empty"
}

function clone_search {
    if [ ! -d "$TMP_CLONE" ]; then
        git clone -q --no-checkout "https://github.com/$GITHUB_REPO.git" "$TMP_CLONE"
    fi
    git -C "$TMP_CLONE" rev-parse "$1"
}

function select_git_sha {
    MODE="$1"
    ARG_SEARCH="$2"
    ARG_LAST_COMMIT="$3"
    if [ -z "$ARG_SEARCH" ]; then
        # skip if we don't have a search term.
        echo "$ARG_LAST_COMMIT"
        return
    fi
    if [ -n "$ARG_LAST_COMMIT" ]; then
        # skip if we already found a full commit.
        echo "$ARG_LAST_COMMIT"
        return
    fi
    case $MODE in
    api-simple)
        # use higher level commit api
        SHA=$(query_github_simple $ARG_SEARCH)
    ;;
    api-treeish)
        # use git database tree api
        SHA=$(query_github_treeish $ARG_SEARCH)
    ;;
    api-short-commit)
        # use github search api if tree api fails.
        SHA=$(search_github_hash $ARG_SEARCH)
    ;;
    full-clone)
        # slow path if Github api fails, full clone
        SHA=$(clone_search $ARG_SEARCH)
    ;;
    esac
    echo "$SHA"
}

EXACT_COMMIT=

# Try GIT_COMMIT
EXACT_COMMIT=$(select_git_sha "api-simple" "$GIT_COMMIT" "$EXACT_COMMIT")
EXACT_COMMIT=$(select_git_sha "api-treeish" "$GIT_COMMIT" "$EXACT_COMMIT")
EXACT_COMMIT=$(select_git_sha "full-clone" "$GIT_COMMIT" "$EXACT_COMMIT")

# Try SHORT_GIT_COMMIT
EXACT_COMMIT=$(select_git_sha "api-simple" "$SHORT_GIT_COMMIT" "$EXACT_COMMIT")
EXACT_COMMIT=$(select_git_sha "api-short-commit" "$SHORT_GIT_COMMIT" "$EXACT_COMMIT")
EXACT_COMMIT=$(select_git_sha "full-clone" "$SHORT_GIT_COMMIT" "$EXACT_COMMIT")

# Try GITHUB_BRANCH_HEAD_SHA
EXACT_COMMIT=$(select_git_sha "api-simple" "$GITHUB_BRANCH_HEAD_SHA" "$EXACT_COMMIT")
EXACT_COMMIT=$(select_git_sha "api-treeish" "$GITHUB_BRANCH_HEAD_SHA" "$EXACT_COMMIT")
EXACT_COMMIT=$(select_git_sha "full-clone" "$GITHUB_BRANCH_HEAD_SHA" "$EXACT_COMMIT")

# Try GITHUB_BRANCH_NAME
EXACT_COMMIT=$(select_git_sha "api-simple" "$GITHUB_BRANCH_NAME" "$EXACT_COMMIT")
EXACT_COMMIT=$(select_git_sha "api-treeish" "$GITHUB_BRANCH_NAME" "$EXACT_COMMIT")
EXACT_COMMIT=$(select_git_sha "full-clone" "$GITHUB_BRANCH_NAME" "$EXACT_COMMIT")

PROPS_PATH=${WORKSPACE}/build.properties
echo "SHORT_GIT_COMMIT=${EXACT_COMMIT:0:7}" > $PROPS_PATH
echo "GIT_COMMIT=${EXACT_COMMIT}" >> $PROPS_PATH
echo "GITHUB_BRANCH_HEAD_SHA=${EXACT_COMMIT}" >> $PROPS_PATH
echo "GITHUB_BRANCH_NAME=${GITHUB_BRANCH_NAME}" >> $PROPS_PATH
echo "GITHUB_REPO=${GITHUB_REPO}" >> $PROPS_PATH

cat $PROPS_PATH
