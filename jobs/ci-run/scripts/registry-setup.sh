#!/bin/bash
set -eux

if ! [ -x "$(command -v aws)" ]; then
    sudo snap install aws-cli --classic || true
fi

REGION="${REGION:-ap-southeast-2}"
DOCKER_REGISTRY="$(aws ecr describe-registry --region ${REGION} | jq -r '.registryId').dkr.ecr.${REGION}.amazonaws.com"
REPOSITORY_NAME_PREFIX="${JOB_NAME}-${JUJU_BUILD_NUMBER}"
OPERATOR_IMAGE_ACCOUNT="${DOCKER_REGISTRY}/${REPOSITORY_NAME_PREFIX}"

ECR_TOKEN=$(aws ecr get-login-password --region "${REGION}")
aws ecr create-repository --repository-name "${REPOSITORY_NAME_PREFIX}/jujud-operator" || true
aws ecr create-repository --repository-name "${REPOSITORY_NAME_PREFIX}/juju-db" || true

JUJU_VERSION_WITHOUT_BUILD_NUMBER=$(echo ${JUJU_VERSION} | cut -d'-' -f 1 | cut -d'.' -f 1,2,3)
JUJU_BUILD_NUMBER_INC=$((JUJU_BUILD_NUMBER+1))
OPERATOR_IMAGE_TAG="${JUJU_VERSION_WITHOUT_BUILD_NUMBER}.${JUJU_BUILD_NUMBER_INC}"

export OPERATOR_IMAGE_ACCOUNT
export JUJU_BUILD_NUMBER_INC
export ECR_TOKEN
export DOCKER_REGISTRY
export SRC_DIR="$WORKSPACE/_build/src/github.com/juju/juju"
export JUJU_DB_TAG=$(grep -r 'DefaultJujuDBSnapChannel =' "${SRC_DIR}/controller/config.go" | sed -r 's/^\s*DefaultJujuDBSnapChannel = \"([[:digit:]]+\.[[:digit:]]+(\.[[:digit:]]+){0,1})\/.*\"$/\1/')

# Capture env and start a new session to get new groups.
SAVE_ENV="$(export -p)"
sudo su - $USER -c "$(echo "$SAVE_ENV" && cat <<'EOS'
    (
        set -eux

        echo ${ECR_TOKEN} | docker login -u AWS --password-stdin ${DOCKER_REGISTRY}
        JUJU_BUILD_NUMBER=${JUJU_BUILD_NUMBER_INC} DOCKER_USERNAME=${OPERATOR_IMAGE_ACCOUNT} make -C ${SRC_DIR} push-release-operator-image

        docker pull jujusolutions/juju-db:${JUJU_DB_TAG}
        docker tag jujusolutions/juju-db:${JUJU_DB_TAG} ${OPERATOR_IMAGE_ACCOUNT}/juju-db:${JUJU_DB_TAG}
        docker push ${OPERATOR_IMAGE_ACCOUNT}/juju-db:${JUJU_DB_TAG}
    )
EOS
)"

set +x
OPERATOR_IMAGE_ACCOUNT=$(jq -r --null-input \
  --arg repository "$OPERATOR_IMAGE_ACCOUNT" \
  --arg serveraddress "$DOCKER_REGISTRY" \
  --arg username "$(sed -n -e 's/^aws_access_key_id = //p' ~/.aws/credentials)" \
  --arg password "$(sed -n -e 's/^aws_secret_access_key = //p' ~/.aws/credentials)" \
  --arg region "$REGION" \
  '{"repository": $repository, "serveraddress": $serveraddress, "username": $username, "password": $password, "region": $region}')
OPERATOR_IMAGE_ACCOUNT_PATH="${WORKSPACE}/operator-image_account.json"
echo "${OPERATOR_IMAGE_ACCOUNT}" > ${OPERATOR_IMAGE_ACCOUNT_PATH}
export OPERATOR_IMAGE_ACCOUNT=${OPERATOR_IMAGE_ACCOUNT_PATH}
echo "OPERATOR_IMAGE_ACCOUNT=${OPERATOR_IMAGE_ACCOUNT_PATH}" >> ${WORKSPACE}/buildvars
set -x
