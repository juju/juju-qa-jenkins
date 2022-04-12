#!/bin/bash
#
# Check provided logs directory for the occurance of any panic messages from
# juju.
# This script is expected to be slurped into a jenkins job config build step.

LOG_DIR=${LOG_DIR:-"${WORKSPACE}/artifacts"}
SEARCH_STRING=${SEARCH_STRING:-"panic:"}

if [ ! -d "${LOG_DIR}" ]; then
    echo "\"${LOG_DIR}\" not found. Not checking logs for panics."
    exit 0
fi

errors_found=$(
    (find ${LOG_DIR}/ -regex ".*/.*machine-[0-9]+\.log\.gz" -print0 | \
        xargs -0 zgrep "${SEARCH_STRING}";) 2>&1)

if [[ $errors_found != "" ]]; then
    printf '=%.0s' {1..100}
    echo -e "\nERROR: Found panic in machine-\d+ logs file(s):"
    printf -- "-%.0s" {1..100}
    echo -e "\n\n${errors_found}"
    exit 1
fi
