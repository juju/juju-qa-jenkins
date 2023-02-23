#!/bin/bash

set -ex

sudo docker run --rm --privileged multiarch/qemu-user-static:register --reset
sudo docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

sudo docker run --mount "type=bind,source=$JUJU_SRC_PATH,target=/juju" "multiarch/ubuntu-core:{arch}-focal" /bin/bash -c '
export DEBIAN_FRONTEND=noninteractive
export TZ=Europe/London
apt-get update
apt-get install sudo build-essential golang-go git curl wget -y
cd /juju
make -j`nproc` MUSL_PRECOMPILED=0 musl-install
'
