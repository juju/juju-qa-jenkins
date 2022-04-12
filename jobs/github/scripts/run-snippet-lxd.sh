#!/bin/bash
set -ex

build_dir=${{BUILD_DIR}}
pr_id=${{ghprbPullId}}

CONTAINER_SERIES=${{CONTAINER_SERIES:-bionic}}

# Shorten the job name - recent tweaks to the container name have made
# it too long.
short_job_name=${{JOB_NAME/#github-check-merge-/ghcm-}}
short_job_name=${{short_job_name/#github-merge-/ghm-}}

SERVER_NAME=$(hostname)
CONTAINER_NAME=pr-check-${{BUILD_NUMBER}}-${{CONTAINER_SERIES}}-${{pr_id}}-${{short_job_name}}-$(date +"%s")
if [ "$CONTAINER_NAME" != "${{CONTAINER_NAME:0:63}}" ]; then
    echo "$CONTAINER_NAME is too long for lxd"
    CONTAINER_NAME_SHA=$(echo "$CONTAINER_NAME" | sha1sum)
    CONTAINER_NAME="${{CONTAINER_NAME:0:58}}-${{CONTAINER_NAME_SHA:0:4}}"
fi
echo "LXD container name is $CONTAINER_NAME"

function attempt_lxd_cmd {{
    # Try a couple of times to delete the container as we sometimes have zfs
    # issues where the dataset is busy.
    local cmd
    cmd=${{1}}

    set +e
    attempts=0
    while [ ${{attempts}} -lt 3 ]; do
        output=$(lxc $cmd --force ${{CONTAINER_NAME}} 2>&1)
        if [ $? -eq 0 ] || [[ $output == *(Error|"not found")* ]]; then
            break
        fi
        attempts=$((attempts+1))
        sleep 10
    done
    set -e
}}

function attempt_lxd_container_stop {{
    attempt_lxd_cmd "stop"
}}

function attempt_lxd_cleanup {{
    attempt_lxd_cmd "delete"
    lxc profile delete "${{CONTAINER_NAME}}" || true
}}

function cleanup {{
    exit_code=$?
    
    set +e
    attempt_lxd_container_stop

    # Need to pull files over at cleanup due to test failures ending the script early.
    echo "Attempting to retrieve test results files."

    set +e
    lxc file pull "$CONTAINER_NAME/home/ubuntu/tests.xml" $WORKSPACE/ || true
    lxc file pull "$CONTAINER_NAME/home/ubuntu/raw-juju-source-vendor.tar.xz" "$WORKSPACE/raw-juju-source-vendor-${{PR_WINDOWS_DATE}}.tar.xz" || true

    # retain container if there was a failure, ensure we stop the containers to
    # prevent utilisation when not required
    if [ $exit_code -ne 0 ]; then
        # Attempt to be helpful and output some useful messages to jenkins for
        # the developer.
        echo "To check the failure, ssh into the container and explore environment. The container is automatically cleaned up after a few hours"
        echo "ssh $SERVER_NAME -t lxc exec $CONTAINER_NAME -- bash"
        echo "Once inside the container:"
        echo "export GOPATH=/workspace"
        echo "cd /workspace/src/github.com/juju/juju"
        echo "go test -v -test.timeout=1500s github.com/juju/juju/..."
    else
        attempt_lxd_cleanup
    fi
}}

trap cleanup EXIT

attempt_lxd_cleanup

# Find prebuilt image
IMAGE_NAME="$JOB_NAME"
PACKAGE_UPGRADE="false"
OUT=$(lxc image list | grep "$JOB_NAME") || true
if [[ -z "$OUT" ]]; then
    IMAGE_NAME="ubuntu:${{CONTAINER_SERIES}}"
    PACKAGE_UPGRADE="true"
fi

RUNCMD="runcmd:"
if [[ ! -z "${{GOVERSION}}" ]]; then
    GOOS=${{GOOS:-linux}}
    GOARCH=${{GOARCH:-amd64}}
    RUNCMD=$(cat <<EOC
${{RUNCMD}}
      - |
        if [ ! -d "/usr/local/go${{GOVERSION}}" ]; then
          echo "Installing go${{GOVERSION}}"
          wget "https://dl.google.com/go/go${{GOVERSION}}.${{GOOS}}-${{GOARCH}}.tar.gz"
          mkdir -p "/usr/local/go${{GOVERSION}}"
          tar -C "/usr/local/go${{GOVERSION}}" --strip-components=1 -xzf "go${{GOVERSION}}.${{GOOS}}-${{GOARCH}}.tar.gz"
        fi
EOC
)
else
    RUNCMD=$(cat <<EOC
${{RUNCMD}} []
EOC
)
fi

# Setup profile
LXD_PROFILE=`mktemp`
cat << EOP > ${{LXD_PROFILE}}
config:
  security.privileged: "true"
  security.nesting: "true"
  limits.memory: 24000MB
  user.user-data: |
    #cloud-config
    package_update: ${{PACKAGE_UPGRADE}}
    packages_upgrade: ${{PACKAGE_UPGRADE}}
    packages:
      - build-essential
      - git
      - make
      - gcc
      - squashfuse
      - jq
    ${{RUNCMD}}
description: ${{CONTAINER_NAME}} image profile
EOP

echo "begin profile for ${{CONTAINER_NAME}}"
cat "${{LXD_PROFILE}}"
echo "end profile for ${{CONTAINER_NAME}}"

lxc profile create "${{CONTAINER_NAME}}" || true
lxc profile edit "${{CONTAINER_NAME}}" < "${{LXD_PROFILE}}"

# Launch container
lxc launch "${{IMAGE_NAME}}" "${{CONTAINER_NAME}}" -p default -p "${{CONTAINER_NAME}}"

# Wait for cloud init to finish
lxc exec "${{CONTAINER_NAME}}" -- bash -c 'cloud-init status --long --wait || (cat /var/log/cloud-init-output.log && false)'

# Maybe add cache from host
if [ -d "/nvme/go-cache" ]; then
    lxc config device add "${{CONTAINER_NAME}}" go-cache disk source=/nvme/go-cache/ path=/go-cache/
fi

# Wait for systemd to finish init
lxc exec "${{CONTAINER_NAME}}" -- bash -c 'while [ "$(systemctl is-system-running 2>/dev/null)" != "running" ] && [ "$(systemctl is-system-running 2>/dev/null)" != "degraded" ]; do :; done'

# The path and size of the tmpfs volume that we will attempt to mount inside the 
# container. Once the jujud tests that compile the agent have been expunged from
# all branches, we can lower this value to about 600M.
USE_TMPFS_FOR_BUILDS=0
TMPFS_VOLUME="/tmp/juju-test.tmp"
TMPFS_VOLUME_SIZE=2500M

# Use TMPFS for mongo database dir
USE_TMPFS_FOR_MGO=1

# Create a env-var file to source in the heredocs do they can use them.
lxc exec "${{CONTAINER_NAME}}" -- sudo -u ubuntu bash <<EOT
    echo "Creating env-var file."
    echo "export PROJECT_DIR=${{PROJECT_DIR}}" >> /tmp/build.env
    # "sudo -u" doesn't set USER, or HOME. Ensure the environment is setup.
    echo "export USER=ubuntu" >> /tmp/build.env
    echo "export HOME=/home/ubuntu" >> /tmp/build.env
    echo "export GOPATH=/home/ubuntu/go" >> /tmp/build.env
    echo "export WORKSPACE=/home/ubuntu/" >> /tmp/build.env
    echo "export XDG_CACHE_HOME=/home/ubuntu/.cache" >> /tmp/build.env
    echo "export GOCACHE=/home/ubuntu/.cache/go-build" >> /tmp/build.env
    echo "export GOVERSION=${{GOVERSION}}" >> /tmp/build.env

    # Add extra envs for build script.
    echo "export NEEDS_MGO=${{NEEDS_MGO}}" >> "${{BUILD_ENV_FILE}}"
    echo "export EXTRA_PACKAGES=${{EXTRA_PACKAGES}}" >> "${{BUILD_ENV_FILE}}"
    echo "export EXTRA_SCRIPT=\"${{EXTRA_SCRIPT}}\"" >> "${{BUILD_ENV_FILE}}"

    # Add the github envs for the checkout script
    echo "repo=$ghprbGhRepository" >> /tmp/build.env
    echo "pr_id=$ghprbPullId" >> /tmp/build.env
    echo "pr_commit=$ghprbActualCommit" >> /tmp/build.env
    echo "target_branch=$ghprbTargetBranch" >> /tmp/build.env
    echo "MONGOD_SOURCE=$MONGOD_SOURCE" >> /tmp/build.env

    # Try to allocate a tmpfs volume for transient test data
    if [ "${{USE_TMPFS_FOR_BUILDS}}" = "1" ]; then
        echo "Attempting to setup a tmpfs volume for storing transient test data"
        mkdir -p ${{TMPFS_VOLUME}}
        mount_status=\$(sudo mount -t tmpfs -o size=${{TMPFS_VOLUME_SIZE}} tmpfs ${{TMPFS_VOLUME}}; echo \$?)
        if [ "\${{mount_status}}" = "0" ]; then
          echo "  - Using a ${{TMPFS_VOLUME_SIZE}} tmpfs volume mounted at ${{TMPFS_VOLUME}}"
          sudo chown ubuntu:ubuntu ${{TMPFS_VOLUME}}
          echo "export TMPDIR=${{TMPFS_VOLUME}}" >> /tmp/build.env
        else
          echo "  - Unable to allocate tmpfs volume; falling back to using the default system temp folder"
        fi
    fi

    if [ "${{USE_TMPFS_FOR_MGO}}" = "1" ]; then
        MGO_TMPFS_VOLUME="/home/ubuntu/snap/juju-db"
        MGO_TMPFS_VOLUME_SIZE=8000M

        echo "sudo mount -t tmpfs -o size=\${{MGO_TMPFS_VOLUME_SIZE}} tmpfs \${{MGO_TMPFS_VOLUME}}"
        mkdir -p \${{MGO_TMPFS_VOLUME}}
        mount_status=\$(sudo mount -t tmpfs -o size=\${{MGO_TMPFS_VOLUME_SIZE}} tmpfs \${{MGO_TMPFS_VOLUME}}; echo \$?)
        if [ "\${{mount_status}}" = "0" ]; then
          echo "  - Using a \${{MGO_TMPFS_VOLUME_SIZE}} tmpfs volume mounted at \${{MGO_TMPFS_VOLUME}}"
          sudo chown ubuntu:ubuntu \${{MGO_TMPFS_VOLUME}}
        else
          echo "  - Unable to allocate tmpfs mongo db volume; falling back to using the default folder"
        fi
    fi

    # Used in the checkout script.
    echo "dest_dir=/home/ubuntu/go/src/${{PROJECT_DIR}}" >> /tmp/build.env

    # Extra env passed in by builder
    cat >> /tmp/build.env <<- EOM
{build_env}
EOM

    if [ -d "/usr/local/go${{GOVERSION}}/go" ]; then
        echo "changing permissions on go ${{GOVERSION}}"
        sudo chown -R "ubuntu" "/usr/local/go${{GOVERSION}}/go"
    fi
    if [ -d "/usr/local/go" ]; then
        echo "changing permissions on go ${{GOVERSION}}"
        sudo chown -R "ubuntu" "/usr/local/go"
    fi

    if [ -d "/go-cache" ]; then
        echo "using go-cache directory from host"
        mkdir -p /home/ubuntu/go/pkg
        mkdir -p /home/ubuntu/.cache/
        mkdir -p /go-cache/ubuntu/go/pkg/mod
        mkdir -p /go-cache/ubuntu/go/pkg/sumdb
        mkdir -p /go-cache/ubuntu/.cache/go-build
        mkdir -p /go-cache/ubuntu/.cache/gophertest
        ln -s /go-cache/ubuntu/go/pkg/mod /home/ubuntu/go/pkg/mod
        ln -s /go-cache/ubuntu/go/pkg/sumdb /home/ubuntu/go/pkg/sumdb
        ln -s /go-cache/ubuntu/.cache/go-build /home/ubuntu/.cache/go-build
        ln -s /go-cache/ubuntu/.cache/gophertest /home/ubuntu/.cache/gophertest
    fi

    mkdir -p /home/ubuntu/go
EOT

# Correctly expand path
lxc exec "${{CONTAINER_NAME}}" -- sudo -u ubuntu bash  <<"EOT"
    source /tmp/build.env
    echo "export PATH=$PATH:$GOPATH/bin:/usr/local/go$GOVERSION/bin" >> /tmp/build.env
EOT

# Run checkout command
lxc exec "${{CONTAINER_NAME}}" -- sudo -u ubuntu bash  <<"EOT"
    source /tmp/build.env
    {checkout_command}
EOT

# Run source command
lxc exec "${{CONTAINER_NAME}}" -- sudo -u ubuntu bash <<"EOT"
    source /tmp/build.env

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
EOT
