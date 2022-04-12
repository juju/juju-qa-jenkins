#!/bin/bash
set -ex

CONTAINER_NAME="ci-build-${{SHORT_GIT_COMMIT}}-${{JOB_NAME}}"
CONTAINER_NAME=$(echo "$CONTAINER_NAME" | tr '[:upper:]' '[:lower:]')
if [ "$CONTAINER_NAME" != "${{CONTAINER_NAME:0:63}}" ]; then
    echo "$CONTAINER_NAME is too long for lxd"
    CONTAINER_NAME_SHA=$(echo "$CONTAINER_NAME" | sha1sum)
    CONTAINER_NAME="${{CONTAINER_NAME:0:58}}-${{CONTAINER_NAME_SHA:0:4}}"
fi
echo "LXD container name is $CONTAINER_NAME"

build_dir=${{WORKSPACE}}/_build
lxd_env_file_path=/home/ubuntu/juju_lxd_env

# For legacy compatibility, set env variable for series if not already set
if [ -z "$JUJU_UNITTEST_SERIES" ]; then
    export JUJU_UNITTEST_SERIES=xenial
fi

function cleanup {{
    # Need to pull files over at cleanup due to test failures ending the script early.
    # Try a couple of times to delete the container as we sometimes have zfs
    # issues where the dataset is busy.

    # Attempt to grab the workspace artifacts before deleting the container.
    mkdir -p ${{WORKSPACE}}/artifacts
    lxc file pull ${{CONTAINER_NAME}}/home/ubuntu/artifacts/output.tar.gz ${{WORKSPACE}}/artifacts/output.tar.gz || true

    attempt_lxd_cleanup

    sudo rm -fr ${{build_dir}} || true
}}

trap cleanup EXIT

function attempt_lxd_cleanup {{
    set +e
    # Delete any containers of the same name. This can happen if you're
    # re-running the same job.
    attempts=0
    while [ ${{attempts}} -lt 3 ]; do
        output=$(lxc delete --force ${{CONTAINER_NAME}} 2>&1)
        if [ $? -eq 0 ] || [[ $output == *(Error|"not found")* ]]; then
            break
        fi
        attempts=$((attempts+1))
        sleep 10
    done
    set -e
}}

attempt_lxd_cleanup

# force the container to be privileged.
output=$(lxc profile list | grep "privileged") || true
if [[ -z $output ]] ; then
    cat << EOF > /tmp/profile.yaml
config:
    security.privileged: "true"
    security.nesting: "true"
EOF
    lxc profile create privileged
    lxc profile edit privileged < /tmp/profile.yaml
fi

output=$(lxc profile list | grep "microk8s") || true
if [[ -z $output ]] ; then
    echo "making microk8s profile"
    cat << EOF > /tmp/microk8s-profile.yaml
name: microk8s
config:
  boot.autostart: "true"
  linux.kernel_modules: ip_vs,ip_vs_rr,ip_vs_wrr,ip_vs_sh,ip_tables,ip6_tables,netlink_diag,nf_nat,overlay,br_netfilter
  raw.lxc: |
    lxc.apparmor.profile=unconfined
    lxc.mount.auto=proc:rw sys:rw cgroup:rw
    lxc.cgroup.devices.allow=a
    lxc.cap.drop=
  security.nesting: "true"
  security.privileged: "true"
description: ""
devices:
  aadisable:
    path: /sys/module/nf_conntrack/parameters/hashsize
    source: /sys/module/nf_conntrack/parameters/hashsize
    type: disk
  aadisable1:
    path: /sys/module/apparmor/parameters/enabled
    source: /dev/null
    type: disk
  aadisable2:
    path: /dev/kmsg
    source: /dev/kmsg
    type: disk
EOF
    lxc profile create microk8s
    lxc profile edit microk8s < /tmp/microk8s-profile.yaml
fi

echo "Using lxd profile privileged"
profile="privileged"

# Check to see if this node has a proxy profile.
PROXY_PROFILE=""
if lxc profile show proxy; then
    PROXY_PROFILE="-p proxy"
fi

lxc init ${{JUJU_UNITTEST_IMAGE}}:${{JUJU_UNITTEST_SERIES}} ${{CONTAINER_NAME}} -p default -p ${{profile}} ${{PROXY_PROFILE}}
lxc config set ${{CONTAINER_NAME}} limits.cpu.allowance 90%

if [ ! -z "${{http_proxy}}" ]; then
    ENV_FILE=$(mktemp)
    lxc file pull ${{CONTAINER_NAME}}/etc/environment $ENV_FILE
    echo "http_proxy=$http_proxy" >> $ENV_FILE
    echo "https_proxy=$http_proxy" >> $ENV_FILE
    echo "ftp_proxy=$http_proxy" >> $ENV_FILE
    lxc file push $ENV_FILE ${{CONTAINER_NAME}}/etc/environment

    SYSTEMD_CONF_FILE=$(mktemp)
    lxc file pull ${{CONTAINER_NAME}}/etc/systemd/system.conf $SYSTEMD_CONF_FILE
    echo "DefaultEnvironment=http_proxy=$http_proxy https_proxy=$http_proxy ftp_proxy=$http_proxy" >> $SYSTEMD_CONF_FILE
    lxc file push $SYSTEMD_CONF_FILE ${{CONTAINER_NAME}}/etc/systemd/system.conf
fi

lxc start ${{CONTAINER_NAME}}

mkdir ${{build_dir}}
stash_dir=${{WORKSPACE}}/_stash
mkdir ${{stash_dir}}
if [ -n "${{JUJU_SRC_TARBALL}}" ]; then
    tar xf ${{JUJU_SRC_TARBALL}} -C ${{build_dir}}
fi
sudo chmod 777 ${{build_dir}}
sudo chmod -R go+w ${{build_dir}}

sudo chmod 777 ${{stash_dir}}
sudo chmod -R go+w ${{stash_dir}}

lxc exec $CONTAINER_NAME -- mkdir /workspace

lxc config device add $CONTAINER_NAME workspace disk path=/workspace source=${{WORKSPACE}}
if [ -d "${{JUJU_DATA}}" ]; then
    lxc config device add $CONTAINER_NAME cloud-city disk path=/var/lib/jenkins/cloud-city source=${{JUJU_DATA}}
fi

# print container's config for debugging purposes.
lxc config show ${{CONTAINER_NAME}}

lxdbr0_addr=$(ip -j address show lxdbr0 | jq -r 'first(.[].addr_info[] | select(.family == "inet") | .local)')
echo "LXD bridge address is $lxdbr0_addr"

lxc exec ${{CONTAINER_NAME}} -- bash <<EOT
    set -e
    while ! tail -1 /var/log/cloud-init-output.log | \
            egrep -q -i 'Cloud-init .* finished'; do
        echo "Waiting for Cloud-init to finish."
        sleep 5
    done

    echo "export LXD_REMOTE_ADDR=$lxdbr0_addr" >> /home/ubuntu/.profile
EOT

# Potentially setup proxy stuff for snapd
if [ ! -z "${{http_proxy}}" ]; then
echo "Setting up proxy details for snapd."

lxc exec ${{CONTAINER_NAME}} -- bash <<EOT
    set -eux
    mkdir -p /etc/systemd/system/snapd.service.d/
    cat > /etc/systemd/system/snapd.service.d/snap_layer_proxy.conf <<-EOL
[Service]
Environment=http_proxy=$http_proxy
Environment=https_proxy=$http_proxy
EOL
    systemctl daemon-reload
    systemctl restart snapd
    echo "export http_proxy=$http_proxy" >> /home/ubuntu/.profile
    echo "export https_proxy=$http_proxy" >> /home/ubuntu/.profile
    echo "export ftp_proxy=$http_proxy" >> /home/ubuntu/.profile
EOT
fi

# TODO - snap store proxy on kabuto is broken so for now, we'll ignore it
#if [ ! -z "${{SNAP_STORE_PROXY}}" ] && [ ! -z "${{SNAP_STORE_ID}}" ]; then
#echo "Configuring snapd inside the lxd container to use snap-store-proxy."
#
#lxc exec ${{CONTAINER_NAME}} -- bash <<EOT
#    set -eux
#    no_proxy=$SNAP_STORE_PROXY curl -sL http://$SNAP_STORE_PROXY/v2/auth/store/assertions | snap ack /dev/stdin
#    snap set system proxy.store=$SNAP_STORE_ID
#    snap set system proxy.http=http://$SNAP_STORE_PROXY
#    snap set system proxy.https=http://$SNAP_STORE_PROXY
#EOT
#fi

if [ -n "{env_file}" ]; then
lxc file push {env_file} ${{CONTAINER_NAME}}$lxd_env_file_path
# work around to ensure the file pushed will be accissible for later usage;
lxc exec ${{CONTAINER_NAME}} -- bash -c "sudo su -c \"chown ubuntu:ubuntu $lxd_env_file_path; chmod 777 $lxd_env_file_path\""
fi

# This might end up being a no-op if setup_steps is not provided.
lxc exec ${{CONTAINER_NAME}} -- sudo -u ubuntu bash <<"EOT"
    # "sudo -u" doesn't set USER, or HOME ensure the environment is setup.
    export USER=ubuntu
    export HOME=/home/ubuntu
    # Pick up any settings that we need.
    source $HOME/.profile

    set +x
    [ -f /home/ubuntu/juju_lxd_env ] && source /home/ubuntu/juju_lxd_env
    set -x

    # Everything following this is injected from a snippet file at job deploy time.
    {setup_steps}
EOT

# restart before doing next steps to allow some changes to take effect(like added $USER to a group).
# wait for 20s until the container full functioning (for example, network, etc).
lxc restart ${{CONTAINER_NAME}} --timeout 10 --force --debug  \
    && sleep 20 \
    && lxc info ${{CONTAINER_NAME}} --show-log

if [ "${{USE_TMPFS_FOR_MGO}}" = "1" ]; then
  echo "Setting up a tmpfs volume for hosting mongo data"
  lxc exec ${{CONTAINER_NAME}} -- sudo -u ubuntu bash <<"EOT"
      MGO_TMPFS_VOLUME="/home/ubuntu/snap/juju-db"
      MGO_TMPFS_VOLUME_SIZE=16000M

      set +x
      mkdir -p ${{MGO_TMPFS_VOLUME}}
      echo "sudo mount -t tmpfs -o size=${{MGO_TMPFS_VOLUME_SIZE}} tmpfs ${{MGO_TMPFS_VOLUME}}"
      mount_status=$(sudo mount -t tmpfs -o size=${{MGO_TMPFS_VOLUME_SIZE}} tmpfs ${{MGO_TMPFS_VOLUME}}; echo $?)
      if [ "${{mount_status}}" = "0" ]; then
        echo "  - Using a ${{MGO_TMPFS_VOLUME_SIZE}} tmpfs volume mounted at ${{MGO_TMPFS_VOLUME}}"
      else
        echo "  - Unable to allocate tmpfs mongo db volume; falling back to using the default folder"
      fi
      set -x
EOT
fi

# Run the command payload passed to the runner script
lxc exec ${{CONTAINER_NAME}} -- sudo -u ubuntu bash <<"EOT"
    # "sudo -u" doesn't set USER, or HOME ensure the environment is setup.
    export USER=ubuntu
    export HOME=/home/ubuntu
    # Pick up any settings that we need.
    source $HOME/.profile

    # Ensure WORKSPACE is present for any snippet that might use it (e.g. unit test script.)
    export WORKSPACE=/workspace

    set -ex
    # Make these available to the calling command. /workspace is '$build_dir'
    # and is root for copying files out of the lxd container.
    # export a 'WORKSPACE' to make this fact a little more transparent.
    export GOPATH=${{WORKSPACE}}/_build
    export full_path=${{GOPATH}}/src/github.com/juju/juju
    export build_dir=${{WORKSPACE}}/_build
    export stash_dir=${{WORKSPACE}}/_stash

    # Override TMPDIR to ensure that tests using the non-snap version of mongo
    # can store their data in the tmpfs volume (if present)
    MGO_TMPFS_VOLUME="/home/ubuntu/snap/juju-db"
    if [ -d "${{MGO_TMPFS_VOLUME}}" ]; then
      echo "Overriding TMPDIR to ${{MGO_TMPFS_VOLUME}}"
      export TMPDIR=${{MGO_TMPFS_VOLUME}}
    fi

    set +x
    [ -f /home/ubuntu/juju_lxd_env ] && source /home/ubuntu/juju_lxd_env
    set -x

    # Include the provided command payload
    {src_command}
EOT

mkdir -p ${{WORKSPACE}}/artifacts
lxc file pull ${{CONTAINER_NAME}}/home/ubuntu/artifacts/output.tar.gz ${{WORKSPACE}}/artifacts/output.tar.gz || true
