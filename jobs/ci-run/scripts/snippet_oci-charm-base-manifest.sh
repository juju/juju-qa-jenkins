set -eux

cd ${build_dir}

# wait for 10s until device ready.
# error: too early for operation, device not yet seeded or device model not acknowledged
sleep 10

# Enabled experimental docker features, must be before login.
# Also add http proxy if we have one
mkdir -p "${HOME}/.docker"
if [ ! -z "${http_proxy:-}" ]; then
cat << EOC > ${HOME}/.docker/config.json
{
    "experimental": "enabled",
    "proxies": {
        "default": {
            "httpProxy": "${http_proxy}",
            "httpsProxy": "${http_proxy}"
        }
    }
}
EOC
else
cat << EOC > ${HOME}/.docker/config.json
{
    "experimental": "enabled"
}
EOC
fi

# Check we can use docker manifest
docker manifest --help

set +x
[ -f ${HOME}/juju_lxd_env ] && export $(grep -v '^#' ${HOME}/juju_lxd_env | xargs)
echo ${DOCKERHUB_P} | docker login -u ${DOCKERHUB_U} --password-stdin
set -x

export DOCKER_USERNAME=${OPERATOR_IMAGE_ACCOUNT}

git clone https://github.com/juju/charm-base-images.git
cd charm-base-images

if ! which go > /dev/null  ; then
  sudo snap install go --classic
fi

(
  IFS=$'\n'
  make print-image-tags | while read -r tag; do
    IMAGE_PATH=${OPERATOR_IMAGE_ACCOUNT}/charm-base:${tag}
    
    echo "Creating manifest for ${IMAGE_PATH}..."
    AMD64_IMAGE_PATH=${OPERATOR_IMAGE_ACCOUNT_PREFIX}amd64/charm-base:${tag} 
    ARM64_IMAGE_PATH=${OPERATOR_IMAGE_ACCOUNT_PREFIX}arm64/charm-base:${tag} 
    PPC64LE_IMAGE_PATH=${OPERATOR_IMAGE_ACCOUNT_PREFIX}ppc64le/charm-base:${tag} 
    S390X_IMAGE_PATH=${OPERATOR_IMAGE_ACCOUNT_PREFIX}s390x/charm-base:${tag} 

    docker pull "${AMD64_IMAGE_PATH}"
    docker pull "${ARM64_IMAGE_PATH}"
    docker pull "${PPC64LE_IMAGE_PATH}"
    docker pull "${S390X_IMAGE_PATH}"

    docker manifest create "${IMAGE_PATH}" "${AMD64_IMAGE_PATH}" "${ARM64_IMAGE_PATH}" "${PPC64LE_IMAGE_PATH}" "${S390X_IMAGE_PATH}"
    docker manifest annotate "${IMAGE_PATH}" "${AMD64_IMAGE_PATH}" --arch amd64
    docker manifest annotate "${IMAGE_PATH}" "${ARM64_IMAGE_PATH}" --arch arm64
    docker manifest annotate "${IMAGE_PATH}" "${PPC64LE_IMAGE_PATH}" --arch ppc64le
    docker manifest annotate "${IMAGE_PATH}" "${S390X_IMAGE_PATH}" --arch s390x

    docker manifest inspect --verbose "${IMAGE_PATH}"

    docker manifest push "${IMAGE_PATH}"
  done
)
