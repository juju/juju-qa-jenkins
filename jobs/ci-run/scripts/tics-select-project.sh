#!/bin/bash
# Select the TICS project for a Juju commit.
#
# This file is sourced, not executed, and must stay POSIX-sh compatible (the
# test harness runs under sh). It expects:
#   JUJU_REPO:   path to a git checkout of juju/juju at the commit to analyse.
#   GIT_COMMIT:  full sha of that commit (used for diagnostics only).
# It sets:
#   TICS_PROJECT: the TICS project the commit's branch uploads to.
#
# Branches are checked in strict precedence order, newest release first, so a
# commit reachable from several supported branches is attributed to the newest
# one. The TICS project for each branch is derived by convention: "juju" for
# the primary release branch and "juju_<branch>" for the others.

TICS_SUPPORTED_BRANCHES="4.1 3.6"

tics_select_project() {
    local branch ref
    for branch in $TICS_SUPPORTED_BRANCHES; do
        ref="origin/${branch}"
        if ! git -C "$JUJU_REPO" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
            echo "ERROR: required ref ${ref} is missing in $JUJU_REPO; cannot verify branch membership for commit $GIT_COMMIT" >&2
            return 2
        fi
        if git -C "$JUJU_REPO" merge-base --is-ancestor HEAD "$ref"; then
            echo "commit $GIT_COMMIT is in the $branch branch"
        if [ "${branch}" = "4.1" ]; then
                TICS_PROJECT=juju
            else
                TICS_PROJECT="juju_${branch}"
            fi
            return 0
        fi
    done
    echo "commit $GIT_COMMIT is not in any supported branch ($(echo $TICS_SUPPORTED_BRANCHES | tr ' ' ', '))... skipping run"
    return 1
}
