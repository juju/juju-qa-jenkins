#!/bin/bash

set -eux

SEED_FILE=${HOME}/juju-build.tar.gz
if [ ! -f ${SEED_FILE} ]; then
    echo `date --rfc-3339=seconds` "seed file: ${SEED_FILE} doesn't exist"
    exit 0
fi

echo `date --rfc-3339=seconds` "extracting ${SEED_FILE}"
(cd ${BUILD_DIR} && tar xzf ${SEED_FILE})
echo `date --rfc-3339=seconds` "extracted ${SEED_FILE}"
