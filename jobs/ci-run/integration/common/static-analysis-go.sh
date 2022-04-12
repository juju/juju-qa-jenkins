    set -eux

    # Term is set to "unknown" in jenkins, so we force it to empty. Ensuring it
    # doesn't error out later on.
    export TERM=""

    cd "${HOME}"
    mkdir "${HOME}"/_build
    cp "${WORKSPACE}"/juju-source-*.tar.xz "${HOME}"/

    tar xf juju-source-*.tar.xz -C _build/
    GOPATH="${HOME}"/_build
    full_path="${GOPATH}"/src/github.com/juju/juju
    export GOPATH="${GOPATH}"

    export PATH="${GOPATH}"/bin:$PATH:/snap/bin:/snap/bin/go/bin

    # Issue around installing a snap within a privileged container on a host
    # fails. There is no real work around once privileged and nesting has been
    # set, so retries succeed.
    attempts=0
    while [ $attempts -lt 3 ]; do
        if [ ! "$(which jq >/dev/null 2>&1)" ]; then
            sudo snap install jq || true
        fi
        if [ ! "$(which shellcheck >/dev/null 2>&1)" ]; then
            sudo snap install shellcheck || true
        fi
        attempts=$((attempts + 1))
    done

    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential

    cd "${full_path}"
    set +e
    make install-snap-dependencies
    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
        set -e
        make install-dependencies
    fi
    set -e

    cd tests

    set -o pipefail
    ./main.sh -v \
        -s test_static_analysis_shell,test_schema \
        -a output.tar.gz \
        -x output.txt \
        static_analysis 2>&1 | tee output.txt
    exit_code=$?
    set +o pipefail

    set +e
    mkdir -p "${HOME}"/artifacts
    mv output.tar.gz "${HOME}"/artifacts/output.tar.gz
    set -e

    exit ${exit_code}
