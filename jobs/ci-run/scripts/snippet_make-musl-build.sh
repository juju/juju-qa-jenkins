#!/bin/bash

set -ex

sudo su

cd ${JUJU_SRC_PATH}
make -j`nproc` MUSL_PRECOMPILED=0 musl-install
