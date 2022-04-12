# shellcheck disable=SC2296

    set -eux

    # Term is set to "unknown" in jenkins, so we force it to empty. Ensuring it
    # doesn't error out later on.
    export TERM=""
    export TEST_RUNNER_NAME="${{TEST_RUNNER_NAME}}"

    cd "$HOME"
    mkdir "$HOME"/_build
    cp "${{WORKSPACE}}"/juju-source-*.tar.xz "$HOME"/

    tar xf juju-source-*.tar.xz -C _build/
    GOPATH="$HOME"/_build
    full_path="$GOPATH"/src/github.com/juju/juju

    if [ ! -d "$full_path"/tests ]; then
        echo "Test directory not found."
        echo "Assuming pre tests setup found, exiting early."
        exit 0
    fi

    export PATH="${{WORKSPACE}}/build":$PATH

    # Copy the juju cloud credentials to ~/.local/share/juju. This is
    # required for bootstrapping non-lxd providers for the integration tests.
    mkdir -p "$HOME"/.local/share/juju
    sudo cp -R "$JUJU_DATA"/. "$HOME"/.local/share/juju
    sudo chown -R "$USER" "$HOME"/.local/share/juju

    sudo apt-get -y update

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
        if [ ! "$(which petname >/dev/null 2>&1)" ]; then
            sudo snap install petname || true
        fi
        if [ ! "$(which make >/dev/null 2>&1)" ]; then
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y make gcc || true
        fi
        if [ ! "$(which go >/dev/null 2>&1)" ]; then
            sudo snap install go --channel=1.17/stable --classic || true
        fi
        # shellcheck disable=SC2193
        if [ "${{BOOTSTRAP_PROVIDER:-}}" = "aws" ]; then
            if [ ! "$(which aws >/dev/null 2>&1)" ]; then
                sudo snap install aws-cli --classic || true
            fi

            mkdir -p "$HOME"/.aws
            echo "[default]" > "$HOME"/.aws/credentials
            cat "$HOME"/.local/share/juju/credentials.yaml |\
                grep aws: -A 4 | grep key: |\
                tail -2 |\
                sed -e 's/      access-key:/aws_access_key_id =/' \
                    -e 's/      secret-key:/aws_secret_access_key =/' \
                >> "$HOME"/.aws/credentials
            echo -e "[default]\nregion = us-east-1" > "$HOME"/.aws/config
            chmod 600 ~/.aws/*
        fi
        attempts=$((attempts + 1))
    done

    # If trying to bootstrap on lxd, use the lxd-remote "provider", which
    # creates containers on the host to avoid nested containers (snap doesn't
    # work with nested containers, and Juju needs snap on focal).
    #
    # shellcheck disable=SC2193
    if [ "${{BOOTSTRAP_PROVIDER:-}}" = "lxd" ]; then
        echo "LXD bootstrap provider: adding lxd-remote cloud at $LXD_REMOTE_ADDR"
        cat >lxd-remote.yaml <<EOF
clouds:
  lxd-remote:
    type: lxd
    auth-types: [interactive, certificate]
    endpoint: ${{LXD_REMOTE_ADDR}}
EOF
        juju add-cloud --client lxd-remote lxd-remote.yaml

        echo "LXD bootstrap provider: adding lxd-remote credentials"
        cat >lxd-remote-creds.yaml <<EOF
credentials:
  lxd-remote:
    admin:
      auth-type: interactive
      trust-password: $(cat "$HOME"/.local/share/juju/lxd-remote-password.txt)
EOF
        juju add-credential --client lxd-remote -f lxd-remote-creds.yaml

        BOOTSTRAP_PROVIDER=lxd-remote
    fi

    cd "$full_path"/tests

    set +x
    OUT=$(./main.sh -H 2>&1)
    if [ "$(echo "$OUT" | grep -q "Illegal option -H" || true)" ]; then
        echo "Not supported runner query."
        exit 1
    elif [ "$(echo "$OUT" | grep -q "${{TEST_RUNNER_NAME}}" || true)" ]; then
        echo "Test ${{TEST_RUNNER_NAME}} not found."
        echo "Recording as success."
        exit 0
    fi
    set -x

    # Export any injected test-runner envvars so they can be picked up by main.sh
    set +u
    export BOOTSTRAP_PROVIDER
    export BOOTSTRAP_CLOUD
    export BOOTSTRAP_SERIES
    export BOOTSTRAP_REUSE_LOCAL
    export OPERATOR_IMAGE_ACCOUNT
    # shellcheck source=/dev/null
    source "$WORKSPACE/buildvars"
    set -u

    echo "=> Running tests"

    mkdir -p "$HOME"/artifacts

    set -o pipefail
    ./main.sh -v \
      -a "$HOME"/artifacts/output.tar.gz \
      -x output.txt \
      -s \""${{TEST_SKIP_TASKS}}"\" \
      "${{TEST_RUNNER_NAME}}" "${{TEST_TASK_NAME}}"  2>&1 | tee output.txt
    exit_code=$?
    set +o pipefail

    exit $exit_code
