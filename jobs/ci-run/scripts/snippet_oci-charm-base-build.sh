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

make build

docker images

(
  IFS=$'\n'
  make print-image-tags | while read -r line; do
    docker push ${OPERATOR_IMAGE_ACCOUNT}/charm-base:${line}
  done
)

