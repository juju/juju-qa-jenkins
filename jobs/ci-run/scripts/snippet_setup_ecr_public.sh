#!/bin/bash
set -eux

if ! [ -x "$(command -v aws)" ]; then
  sudo snap install aws-cli --classic || true
fi

if ! [ -x "$(command -v skopeo)" ]; then
  sudo apt-get install skopeo
fi

aws ecr-public create-repository --repository-name "build-${SHORT_GIT_COMMIT}/jujud-operator" || true
aws ecr-public create-repository --repository-name "build-${SHORT_GIT_COMMIT}/juju-db" || true
aws ecr-public create-repository --repository-name "build-${SHORT_GIT_COMMIT}/charm-base" || true

aws ecr-public get-login-password | skopeo login -u AWS --password-stdin public.ecr.aws

# use the latest skopeo for doing the actual copy.
podman run --rm -v $XDG_RUNTIME_DIR/containers/auth.json:/auth.json quay.io/skopeo/stable:latest copy --authfile /auth.json --all docker://public.ecr.aws/juju/juju-db:4.4 docker://public.ecr.aws/jujuqabot/build-${SHORT_GIT_COMMIT}/juju-db:4.4 &
podman run --rm -v $XDG_RUNTIME_DIR/containers/auth.json:/auth.json quay.io/skopeo/stable:latest copy --authfile /auth.json --all docker://public.ecr.aws/juju/charm-base:ubuntu-18.04 docker://public.ecr.aws/jujuqabot/build-${SHORT_GIT_COMMIT}/charm-base:ubuntu-18.04 &
podman run --rm -v $XDG_RUNTIME_DIR/containers/auth.json:/auth.json quay.io/skopeo/stable:latest copy --authfile /auth.json --all docker://public.ecr.aws/juju/charm-base:ubuntu-20.04 docker://public.ecr.aws/jujuqabot/build-${SHORT_GIT_COMMIT}/charm-base:ubuntu-20.04 &
podman run --rm -v $XDG_RUNTIME_DIR/containers/auth.json:/auth.json quay.io/skopeo/stable:latest copy --authfile /auth.json --all docker://public.ecr.aws/juju/charm-base:ubuntu-22.04 docker://public.ecr.aws/jujuqabot/build-${SHORT_GIT_COMMIT}/charm-base:ubuntu-22.04 &
podman run --rm -v $XDG_RUNTIME_DIR/containers/auth.json:/auth.json quay.io/skopeo/stable:latest copy --authfile /auth.json --all docker://public.ecr.aws/juju/charm-base:ubuntu-24.04 docker://public.ecr.aws/jujuqabot/build-${SHORT_GIT_COMMIT}/charm-base:ubuntu-24.04 &
wait
