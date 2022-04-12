#!/bin/bash
set -ex

function wait_for_dpkg() {{
    # Just in case, wait for cloud-init.
    cloud-init status --wait 2> /dev/null || true
    while sudo lsof /var/lib/dpkg/lock-frontend 2> /dev/null; do
        echo "Waiting for dpkg lock..."
        sleep 10
    done
    while sudo lsof /var/lib/apt/lists/lock 2> /dev/null; do
        echo "Waiting for apt lock..."
        sleep 10
    done
}}

# For compatability reasons we need to kill GOOS and GOARCH.
unset GOOS
unset GOARCH
export BUILD_ENV_FILE=$(mktemp)

(
    build_dir="${{BUILD_DIR}}"
    pr_id="${{ghprbPullId}}"

    SERVER_NAME=$(hostname)

    # The path and size of the tmpfs volume that we will attempt to mount inside the 
    # container. Once the jujud tests that compile the agent have been expunged from
    # all branches, we can lower this value to about 600M.
    USE_TMPFS_FOR_BUILDS="0"
    TMPFS_VOLUME="/tmp/juju-test.tmp"
    TMPFS_VOLUME_SIZE="2500M"

    # Use TMPFS for mongo database dir
    USE_TMPFS_FOR_MGO="1"

    echo "Creating env-var file."
    echo "export PROJECT_DIR=${{PROJECT_DIR}}" >> "${{BUILD_ENV_FILE}}"
    echo "export USER=${{USER}}" >> "${{BUILD_ENV_FILE}}"
    echo "export HOME=/home/${{USER}}" >> "${{BUILD_ENV_FILE}}"
    echo "export GOPATH=/home/${{USER}}/go" >> "${{BUILD_ENV_FILE}}"
    echo "export WORKSPACE=/home/${{USER}}/" >> "${{BUILD_ENV_FILE}}"
    echo "export XDG_CACHE_HOME=/home/${{USER}}/.cache" >> "${{BUILD_ENV_FILE}}"
    echo "export GOCACHE=/home/${{USER}}/.cache/go-build" >> "${{BUILD_ENV_FILE}}"

    # Add the github envs for the checkout script
    echo "repo=$ghprbGhRepository" >> "${{BUILD_ENV_FILE}}"
    echo "pr_id=$ghprbPullId" >> "${{BUILD_ENV_FILE}}"
    echo "pr_commit=$ghprbActualCommit" >> "${{BUILD_ENV_FILE}}"
    echo "target_branch=$ghprbTargetBranch" >> "${{BUILD_ENV_FILE}}"
    echo "MONGOD_SOURCE=$MONGOD_SOURCE" >> "${{BUILD_ENV_FILE}}"

    # Add extra envs for build script.
    echo "export NEEDS_MGO=${{NEEDS_MGO}}" >> "${{BUILD_ENV_FILE}}"
    echo "export EXTRA_PACKAGES=${{EXTRA_PACKAGES}}" >> "${{BUILD_ENV_FILE}}"
    echo "export EXTRA_SCRIPT=\"${{EXTRA_SCRIPT}}\"" >> "${{BUILD_ENV_FILE}}"

    # Try to allocate a tmpfs volume for transient test data
    if [ "${{USE_TMPFS_FOR_BUILDS}}" = "1" ]; then
        echo "Attempting to setup a tmpfs volume for storing transient test data"
        mkdir -p "${{TMPFS_VOLUME}}"
        mount_status=$(sudo mount -t tmpfs -o size=${{TMPFS_VOLUME_SIZE}} tmpfs ${{TMPFS_VOLUME}}; echo $?)
        if [ "${{mount_status}}" = "0" ]; then
            echo "  - Using a ${{TMPFS_VOLUME_SIZE}} tmpfs volume mounted at ${{TMPFS_VOLUME}}"
            sudo chown ${{USER}}:${{USER}} "${{TMPFS_VOLUME}}"
            echo "export TMPDIR=${{TMPFS_VOLUME}}" >> "${{BUILD_ENV_FILE}}"
        else
            echo "  - Unable to allocate tmpfs volume; falling back to using the default system temp folder"
        fi
    fi

    if [ "${{USE_TMPFS_FOR_MGO}}" = "1" ]; then
        MGO_TMPFS_VOLUME="/home/${{USER}}/snap/juju-db"
        MGO_TMPFS_VOLUME_SIZE="8000M"

        echo "sudo mount -t tmpfs -o size=${{MGO_TMPFS_VOLUME_SIZE}} tmpfs ${{MGO_TMPFS_VOLUME}}"
        mkdir -p "${{MGO_TMPFS_VOLUME}}"
        mount_status=$(sudo mount -t tmpfs -o size=${{MGO_TMPFS_VOLUME_SIZE}} tmpfs ${{MGO_TMPFS_VOLUME}}; echo $?)
        if [ "${{mount_status}}" = "0" ]; then
            echo "  - Using a ${{MGO_TMPFS_VOLUME_SIZE}} tmpfs volume mounted at ${{MGO_TMPFS_VOLUME}}"
            sudo chown ${{USER}}:${{USER}} "${{MGO_TMPFS_VOLUME}}"
        else
            echo "  - Unable to allocate tmpfs mongo db volume; falling back to using the default folder"
        fi
    fi

    # Used in the checkout script.
    echo "dest_dir=/home/${{USER}}/go/src/${{PROJECT_DIR}}" >> "${{BUILD_ENV_FILE}}"

    # Extra env passed in by builder
    cat >> "${{BUILD_ENV_FILE}}" <<- EOM
{build_env}
EOM
)

wait_for_dpkg

# Run setup steps
(
    source "${{BUILD_ENV_FILE}}"
    echo "Running setup steps..."
    {setup_steps}
)

wait_for_dpkg

# Capture env and start a new session to get new groups.
SAVE_ENV="$(export -p)"
# Run checkout command
sudo su - "$USER" -c "$(echo "$SAVE_ENV" && cat <<'EOS'
(
    source "${{BUILD_ENV_FILE}}"
    echo "Running checkout command..."
    {checkout_command}
)
EOS
)"

wait_for_dpkg

# Capture env and start a new session to get new groups.
SAVE_ENV="$(export -p)"
# Run source command
sudo su - "$USER" -c "$(echo "$SAVE_ENV" && cat <<'EOS'
(
    source "${{BUILD_ENV_FILE}}"
    
    echo "Running source command..."
    env

    # The snippet portion (just below) *must* set check_exit to the desired exit
    # code otherwise default to exit non-zero.
    check_exit=1
{src_command}

    # To generate a xunit report The snippet must produce the file
    # 'go-unittest.out' with the test run output in it
    #   (i.e. from 'go test -v...)
    if [ -f "${{WORKSPACE}}/go-unittest.out" ]; then
        # This will be used to generate reports for jenkins assuming there is
        # a file "go-unittest.out" in the WORKSPACE.
        GO111MODULE=off go get -v github.com/tebeka/go2xunit
        "${{GOPATH}}/bin/go2xunit" -fail -input "${{WORKSPACE}}/go-unittest.out" -output "${{WORKSPACE}}/tests.xml"
    fi

    # Make sure we exit with the right error code and that it's not overwritten by anything.
    # We trust make check explicitly to return the correct code; not go2xunit
    if [ $check_exit -ne 0 ]; then
        exit $check_exit
    fi

    check_exit=1
{test_command}
    # Make sure we exit with the right error code
    exit $check_exit
)
EOS
)"
