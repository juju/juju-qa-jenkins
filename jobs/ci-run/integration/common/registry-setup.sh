#!/bin/bash
set -eux

if ! [ -x "$(command -v aws)" ]; then
  sudo snap install aws-cli --classic || true
fi

REGION="${REGION:-us-east-1}"
DOCKER_REGISTRY="$(aws ecr describe-registry --region "${REGION}" | jq -r '.registryId').dkr.ecr.${REGION}.amazonaws.com"
REPOSITORY_NAME_PREFIX="${JOB_NAME}-${JUJU_BUILD_NUMBER}"
OPERATOR_IMAGE_ACCOUNT="${DOCKER_REGISTRY}/${REPOSITORY_NAME_PREFIX}"

ECR_TOKEN=$(aws ecr get-login-password --region "${REGION}")
aws ecr create-repository --repository-name "${REPOSITORY_NAME_PREFIX}/jujud-operator" || true
aws ecr create-repository --repository-name "${REPOSITORY_NAME_PREFIX}/juju-db" || true
aws ecr create-repository --repository-name "${REPOSITORY_NAME_PREFIX}/charm-base" || true

JUJU_DB_TAG=$(grep -r 'DefaultJujuDBSnapChannel =' "${JUJU_SRC_PATH}/controller/config.go" | sed -r 's/^\s*DefaultJujuDBSnapChannel = \"([[:digit:]]+\.[[:digit:]]+(\.[[:digit:]]+){0,1})\/.*\"$/\1/')

export OPERATOR_IMAGE_ACCOUNT
export ECR_TOKEN
export DOCKER_REGISTRY
export JUJU_DB_TAG

# Capture env and start a new session to get new groups.
echo "${ECR_TOKEN}" | docker login -u AWS --password-stdin "${DOCKER_REGISTRY}"
DOCKER_USERNAME=${OPERATOR_IMAGE_ACCOUNT} make -C "${JUJU_SRC_PATH}" push-release-operator-image

# Copy juju-db from docker
docker pull "jujusolutions/juju-db:${JUJU_DB_TAG}"
docker tag "jujusolutions/juju-db:${JUJU_DB_TAG}" "${OPERATOR_IMAGE_ACCOUNT}/juju-db:${JUJU_DB_TAG}"
docker push "${OPERATOR_IMAGE_ACCOUNT}/juju-db:${JUJU_DB_TAG}"

# Copy LTS charm bases from docker
BASES=(18.04 20.04 22.04)
for BASE in "${BASES[@]}" ; do
  docker pull "jujusolutions/charm-base:ubuntu-${BASE}"
  docker tag "jujusolutions/charm-base:ubuntu-${BASE}" "${OPERATOR_IMAGE_ACCOUNT}/charm-base:ubuntu-${BASE}"
  docker push "${OPERATOR_IMAGE_ACCOUNT}/charm-base:ubuntu-${BASE}"
done

set +x
OPERATOR_IMAGE_ACCOUNT=$(jq -r --null-input \
  --arg repository "$OPERATOR_IMAGE_ACCOUNT" \
  --arg serveraddress "$DOCKER_REGISTRY" \
  --arg username "$(sed -n -e 's/^aws_access_key_id = //p' ~/.aws/credentials)" \
  --arg password "$(sed -n -e 's/^aws_secret_access_key = //p' ~/.aws/credentials)" \
  --arg region "$REGION" \
  '{"repository": $repository, "serveraddress": $serveraddress, "username": $username, "password": $password, "region": $region}')
OPERATOR_IMAGE_ACCOUNT_PATH="${WORKSPACE}/operator-image_account.json"
echo "${OPERATOR_IMAGE_ACCOUNT}" > "${OPERATOR_IMAGE_ACCOUNT_PATH}"
export OPERATOR_IMAGE_ACCOUNT=${OPERATOR_IMAGE_ACCOUNT_PATH}
echo "OPERATOR_IMAGE_ACCOUNT=${OPERATOR_IMAGE_ACCOUNT_PATH}" >> "${WORKSPACE}/buildvars"
set -x
