#!/bin/bash
set -xe

if [ -z "$GITHUB_BRANCH_NAME" ] && [ -z "$GITHUB_BRANCH_HEAD_SHA" ]; then
    echo "Must specify one of GITHUB_BRANCH_NAME or GITHUB_BRANCH_HEAD_SHA"
    exit 1
fi

if [ -z "$JUJU_SOURCE_CHECKOUT" ]; then
    echo "Must specify JUJU_SOURCE_CHECKOUT"
    exit 1
fi

export PATH="/snap/bin:$PATH"
sudo snap refresh go --channel=1.21/stable || sudo snap install go --channel=1.21/stable --classic

# TODO - fix this workaround
# As we clone the full history (can't shallow clone otherwise queued jobs miss
# out when only the most recent commit is pulled).
# To limit the sizes of the tarballs moved around (and no need to have full
# history for a build)
# We do a 2 part clone, the initial clone done by the job, then reduce that to
# depth=1
export GOPATH=${WORKSPACE}/build
full_path=${GOPATH}/src/github.com/juju/juju

export PATH=/snap/bin:$PATH:$GOPATH/bin

# If run with an overriding SHORT_GIT_COMMIT we need to
# determine the branch name ourselves.
if [ -z ${GITHUB_BRANCH_NAME} ]; then
    GITHUB_BRANCH_NAME=$(git -C ${JUJU_SOURCE_CHECKOUT} branch --all \
        --contains ${GITHUB_BRANCH_HEAD_SHA} \
        --column \
        | awk '{print$NF}' \
        | awk -F/ '{print$NF}')
fi
rm -rf ${full_path}
git clone --depth 1 file://${JUJU_SOURCE_CHECKOUT} ${full_path}
rm -fr ${JUJU_SOURCE_CHECKOUT}

# TODO - remove vendor mode for go mod
# It currently is needed for s390x builds since the s390x slave
# is on a restricted network.
echo "Resolving dependencies"
export JUJU_MAKE_DEP=true
export JUJU_GOMOD_MODE=vendor
make -C ${full_path} godeps || make -C ${full_path} dep || make -C ${full_path} vendor-dependencies

echo "Removing non-free data."
rm -rf ${GOPATH}/src/github.com/rogpeppe/godeps
rm -rf ${GOPATH}/src/github.com/golang/dep
rm -rf ${GOPATH}/src/github.com/kisielk
rm -rf ${GOPATH}/src/code.google.com/p/go.net/html/charset/testdata/
rm -f ${GOPATH}/src/code.google.com/p/go.net/html/charset/*test.go
rm -rf ${GOPATH}/src/golang.org/x/net/html/charset/testdata/
rm -f ${GOPATH}/src/golang.org/x/net/html/charset/*test.go
rm -rf ${GOPATH}/src/github.com/prometheus/procfs/fixtures

# Remove backup files that confuse lintian.
echo "Removing backup files"
find ${GOPATH}/src/ -type f -name *.go.orig -delete

echo "Attempting to apply patches"
(cd ${full_path} && GOPATH=${GOPATH} make add-patches || true)

echo "Removing binaries and build artifacts"
if [[ -d ${GOPATH}/bin ]]; then
    rm -r ${GOPATH}/bin
fi
if [[ -d ${GOPATH}/pkg ]]; then
    # go mod prevents writes
    chmod +w -R ${GOPATH}/pkg
    rm -r ${GOPATH}/pkg
fi

PROPS_PATH=${WORKSPACE}/build.properties
#  Need to prepare some variables used through out the process
JUJU_VERSION=$(sed -n 's/^const version = "\(.*\)"/\1/p' ${full_path}/version/version.go)
if [[ -n ${JUJU_BUILD_NUMBER:-} ]]; then
    JUJU_VERSION="${JUJU_VERSION}.${JUJU_BUILD_NUMBER}"
fi

# GIT_COMMIT is used by juju Makefile for version info.
GIT_COMMIT=$(git -C ${full_path} rev-parse HEAD)
SHORT_GIT_COMMIT=${GIT_COMMIT:0:7}
echo "SHORT_GIT_COMMIT=${SHORT_GIT_COMMIT}" >> $PROPS_PATH
echo "GIT_COMMIT=${GIT_COMMIT}" >> $PROPS_PATH
echo "GOVERSION=${GOVERSION}" >> $PROPS_PATH
echo "JUJU_BUILD_NUMBER=${JUJU_BUILD_NUMBER}" >> $PROPS_PATH
echo "JUJU_VERSION=${JUJU_VERSION}" >> $PROPS_PATH
echo "JUJU_GOMOD_MODE=${JUJU_GOMOD_MODE}" >> $PROPS_PATH
echo "JUJU_SRC_TARBALL=juju-source-${JUJU_VERSION}-${SHORT_GIT_COMMIT}.tar.xz" >> $PROPS_PATH
echo "JUJU_VERSION_MAJOR_MINOR=$(echo ${JUJU_VERSION} | cut -d'-' -f 1 | cut -d'.' -f 1,2)" >> $PROPS_PATH

source ${WORKSPACE}/build.properties

tar cfJ ${JUJU_SRC_TARBALL} \
    --exclude .git --exclude .bzr --exclude .hg \
    -C ${GOPATH} ./