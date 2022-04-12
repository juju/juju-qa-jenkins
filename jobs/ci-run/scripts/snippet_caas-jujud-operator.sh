set -eux

cd ${full_path}

# DO NOT build jujud here, and always copy from existing build.
export OPERATOR_IMAGE_BUILD_SRC=false

if [ -z "${JUJU_BUILD_NUMBER+''}" ]; then
  OCI_IMAGE_PLATFORMS="${BUILD_PLATFORMS//,/ }" make push-release-operator-image
else
  OCI_IMAGE_PLATFORMS="${BUILD_PLATFORMS//,/ }" make push-operator-image
fi
