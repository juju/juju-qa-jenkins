#!/bin/bash
set -eux
PATH=$GOPATH/bin:$PATH

echo "fetching supported branch refs..."
git -C "$WORKSPACE/juju" fetch origin +refs/heads/3.6:refs/remotes/origin/3.6 +refs/heads/4.1:refs/remotes/origin/4.1

JUJU_REPO="$WORKSPACE/juju"
