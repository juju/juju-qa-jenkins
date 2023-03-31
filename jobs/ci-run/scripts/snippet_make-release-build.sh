#!/bin/bash

set -eux

echo GIT_COMMIT=${{GIT_COMMIT}}
echo JUJU_GOMOD_MODE=${{JUJU_GOMOD_MODE}}
echo CLIENT_PACKAGE_PLATFORMS=${{CLIENT_PACKAGE_PLATFORMS}}
echo AGENT_PACKAGE_PLATFORMS=${{AGENT_PACKAGE_PLATFORMS}}
echo BUILD_TAGS=${{BUILD_TAGS:-}}

cd ${{JUJU_SRC_PATH}}
build_type=$(grep "go-agent-build-no-cgo" Makefile >/dev/null && echo "no-cgo" || echo "")
if [ $build_type = "no-cgo" ]; then
    GOOS=$(echo $AGENT_PACKAGE_PLATFORMS | cut -d/ -f 1) \
    GOARCH=$(echo $AGENT_PACKAGE_PLATFORMS | cut -d/ -f 2 | sed "s/ppc64el/ppc64le/") \
        make -j`nproc` go-build BUILD_TAGS="${{BUILD_TAGS:-}}"
else
    make -j`nproc` go-build BUILD_TAGS="${{BUILD_TAGS:-}}"
fi
