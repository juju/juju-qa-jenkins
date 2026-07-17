#!/bin/bash
set -xe

PROPS_PATH=${WORKSPACE}/build.properties
if [[ "${COVERAGE_ENABLED:-false}" != "true" ]]; then
    echo "INTEGRATION_COVERAGE_COLLECT_URL=" >> $PROPS_PATH
    echo "UNIT_COVERAGE_COLLECT_URL=" >> $PROPS_PATH
    exit 0
fi

cat | tee ${WORKSPACE}/integration-coverage-info <<EOF
type=integration
git=${GIT_COMMIT}
EOF
INTEGRATION_NAMESPACE=$(openssl dgst -sha256 -hmac "${COVERAGE_PRESHAREDKEY}" "${WORKSPACE}/integration-coverage-info" | awk '{print $2}')
curl --upload-file ${WORKSPACE}/integration-coverage-info "${COVERAGE_SERVER_URL}/${INTEGRATION_NAMESPACE}"

cat | tee ${WORKSPACE}/unit-coverage-info <<EOF
type=unit
git=${GIT_COMMIT}
EOF
UNIT_NAMESPACE=$(openssl dgst -sha256 -hmac "${COVERAGE_PRESHAREDKEY}" "${WORKSPACE}/unit-coverage-info" | awk '{print $2}')
curl --upload-file ${WORKSPACE}/unit-coverage-info "${COVERAGE_SERVER_URL}/${UNIT_NAMESPACE}"

echo "INTEGRATION_COVERAGE_COLLECT_URL=${COVERAGE_SERVER_URL}/${INTEGRATION_NAMESPACE}/covdata" >> $PROPS_PATH
echo "UNIT_COVERAGE_COLLECT_URL=${COVERAGE_SERVER_URL}/${UNIT_NAMESPACE}/covdata" >> $PROPS_PATH
