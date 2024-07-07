#!/bin/bash

set -eux

echo GIT_COMMIT=${GIT_COMMIT}
echo JUJU_GOMOD_MODE=${JUJU_GOMOD_MODE}
echo CLIENT_PACKAGE_PLATFORMS=${CLIENT_PACKAGE_PLATFORMS}
echo AGENT_PACKAGE_PLATFORMS=${AGENT_PACKAGE_PLATFORMS}
echo BUILD_TAGS=${BUILD_TAGS:-}

cd ${JUJU_SRC_PATH}

# Feature detection for cgo. We should really have a better way to do this.
# Note: we can't detect CGO in the Makefile, as we've got references to cgo
# inside the Makefile.
build_type=$(grep "go-agent-build-no-cgo" Makefile >/dev/null && echo "cgo" || echo "")
if [ $build_type = "cgo" ]; then
    GOOS=$(echo $AGENT_PACKAGE_PLATFORMS | cut -d/ -f 1) \
    GOARCH=$(echo $AGENT_PACKAGE_PLATFORMS | cut -d/ -f 2 | sed "s/ppc64el/ppc64le/") \
        make -j`nproc` go-build BUILD_TAGS="${BUILD_TAGS:-}"
else
    make -j`nproc` go-build BUILD_TAGS="${BUILD_TAGS:-}"
fi
