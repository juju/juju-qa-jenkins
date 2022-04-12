#!/bin/bash
set -e

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

export artifacts_dir=${{WORKSPACE}}/artifacts
export build_dir=${{WORKSPACE}}/_build
export stash_dir=${{WORKSPACE}}/_stash

(
    mkdir ${{artifacts_dir}}
    mkdir ${{build_dir}}
    mkdir ${{stash_dir}}

    if [ -n "${{JUJU_SRC_TARBALL}}" ]; then
        tar xf ${{JUJU_SRC_TARBALL}} -C ${{build_dir}}
    fi
    sudo chmod 777 ${{build_dir}}
    sudo chmod -R go+w ${{build_dir}}

    sudo chmod 777 ${{stash_dir}}
    sudo chmod -R go+w ${{stash_dir}}
)

set -a
[ -f "{env_file}" ] && source "{env_file}"
set +a

wait_for_dpkg

sudo apt-get update

(
    echo "Running pre test steps..."
    {pre_test_steps}
)

(
    echo "Running setup steps..."
    {setup_steps}
)

wait_for_dpkg

export GOPATH=${{build_dir}}
export full_path=${{GOPATH}}/src/github.com/juju/juju

# Capture env and start a new session to get new groups.
SAVE_ENV="$(export -p)"
sudo su - $USER -c "$(echo "$SAVE_ENV" && cat <<'EOS'
(
    echo "Running build steps..."
    {src_command}
)
EOS
)"
