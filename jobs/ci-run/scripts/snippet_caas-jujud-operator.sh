#!/bin/bash
set -eux

cd ${JUJU_SRC_PATH}

# DO NOT build jujud here, and always copy from existing build.
export OPERATOR_IMAGE_BUILD_SRC=false

# push both build number and non-build number tags
JUJU_BUILD_NUMBER=0 OCI_IMAGE_PLATFORMS="${BUILD_PLATFORMS//,/ }" make push-release-operator-image
OCI_IMAGE_PLATFORMS="${BUILD_PLATFORMS//,/ }" make push-operator-image
