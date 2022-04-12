#!/bin/sh -e

# Always ignore SC2230 ('which' is non-standard. Use builtin 'command -v' instead.)
export SHELLCHECK_OPTS="-e SC2230 -e SC2039 -e SC2028 -e SC2002 -e SC2005"

OPTIND=1
VERBOSE=1

import_subdir_files() {
    test "$1"
    local file
    for file in "$1"/*.sh; do
        # shellcheck disable=SC1090
        . "$file"
    done
}

import_subdir_files includes

# If adding a test suite, then ensure to add it here to be picked up!
TEST_NAMES="test_smoke \
            test_static_analysis"

show_help() {
    echo ""
    echo "$(red 'Jenkins test suite')"
    echo "¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯"
    echo ""
    echo "Usage:"
    echo "¯¯¯¯¯¯"
    echo "cmd [-h] [-vV]"
    echo ""
    echo "    $(green 'cmd -h')        Display this help message"
    echo "    $(green 'cmd -v')        Verbose and debug messages"
    echo "    $(green 'cmd -V')        Very verbose and debug messages"
    echo ""
    echo "Tests:"
    echo "¯¯¯¯¯¯"
    echo "Available tests:"
    echo ""

    # Let's use the TEST_NAMES to print out what's available
    output=""
    for test in ${TEST_NAMES}; do
        name=$(echo "${test}" | sed -E "s/^run_//g" | sed -E "s/_/ /g")
        # shellcheck disable=SC2086
        output="${output}\n    $(green ${test})|Runs the ${name}"
    done
    echo "${output}" | column -t -s "|"

    echo ""
    echo "Examples:"
    echo "¯¯¯¯¯¯¯¯¯"
    echo "Run a singular test:"
    echo ""
    echo "    $(green 'cmd static_analysis test_static_analysis_go')"
    echo ""
    exit 0
}

while getopts "h?:vV" opt; do
    case "${opt}" in
    h|\?)
        show_help
        ;;
    v)
        VERBOSE=1
        shift
        ;;
    V)
        VERBOSE=2
        shift
        ;;
    *)
        echo "Unexpected argument ${opt}" >&2
        exit 1
    esac
done

shift $((OPTIND-1))

[ "${1:-}" = "--" ] && shift

export VERBOSE="${VERBOSE}"

echo ""

echo "==> Checking for dependencies"
check_dependencies curl jq shellcheck

if [ "${USER:-'root'}" = "root" ]; then
    echo "The testsuite must not be run as root." >&2
    exit 1
fi

cleanup() {
    # Allow for failures and stop tracing everything
    set +ex

    echo "==> Cleaning up"
    echo ""
    if [ "${TEST_RESULT}" != "success" ]; then
        echo "==> TESTS DONE: ${TEST_CURRENT_DESCRIPTION}"
    fi
    echo "==> Test result: ${TEST_RESULT}"

    if [ "${TEST_RESULT}" = "success" ]; then
        rm -rf "${TEST_DIR}"
        echo "==> Tests Removed: ${TEST_DIR}"
    fi

    echo "==> TEST COMPLETE"
}

TEST_CURRENT=setup
TEST_RESULT=failure

trap cleanup EXIT HUP INT TERM

# Setup test directory
TEST_DIR=$(mktemp -d tmp.XXX | xargs -I % echo "$(pwd)/%")

run_test() {
    TEST_CURRENT=${1}
    TEST_CURRENT_DESCRIPTION=${2:-${1}}
    TEST_CURRENT_NAME=${TEST_CURRENT#"test_"}

    if [ -n "${4}" ]; then
        TEST_CURRENT=${4}
    fi

    import_subdir_files "suites/${TEST_CURRENT_NAME}"

    echo "==> TEST BEGIN: ${TEST_CURRENT_DESCRIPTION}"
    START_TIME=$(date +%s)
    ${TEST_CURRENT}
    END_TIME=$(date +%s)

    echo "==> TEST DONE: ${TEST_CURRENT_DESCRIPTION} ($((END_TIME-START_TIME))s)"
}

# allow for running a specific set of tests
if [ "$#" -gt 0 ]; then
    run_test "test_${1}" "" "$@"
    TEST_RESULT=success
    exit
fi

for test in ${TEST_NAMES}; do
    name=$(echo "${test}" | sed -E "s/^run_//g" | sed -E "s/_/ /g")
    run_test "${test}" "${name}"
done

TEST_RESULT=success
