#!/bin/bash

# Setup forwarding for testing non-manual clouds which are always present in
# the example-clouds file (maas/vsphere)
sshuttle -r finfolk 10.0.30.0/24 --daemon
sshuttle -r munna 10.247.0.0/24 --daemon --pidfile sshuttle-vsphere.pid

# Spin up containers for various distros and set up ssh access to emulate
# a manual machine. We append the branch SHA to the container name so
# multiple test runs can run in parallel.
SSH_HOST_PUB_KEY="${HOME}/.ssh/id_rsa.pub"
MANUAL_MACH_DISTROS="xenial bionic focal"
CONTAINER_NAME_PREFIX="add-cloud-many"

# Make a copy of the template file with the cloud sections so we can append the
# entries for the containers we create below.
clouds_file="/tmp/cloud-list-${SHORT_GIT_COMMIT}.yaml"
(
cat << EOF
clouds:
  finfolk-vmaas:
    type: maas
    auth-types: [oauth1]
    endpoint: http://10.125.0.10:5240/MAAS/
  vsphere:
    type: vsphere
    auth-types: [userpass]
    endpoint: 10.247.0.3
    regions:
      QA:
        endpoint: 10.247.0.3
EOF
) > "${clouds_file}"

# NOTE(achilleasa): instead of using a trap here, the cleanup logic for ssshuttle
# the temp clouds file and the manual containers has been moved to a post-build
# step which jenkins will call even if the job gets aborted.

for distro in ${MANUAL_MACH_DISTROS}; do
  container_name="${CONTAINER_NAME_PREFIX}-${distro}-${SHORT_GIT_COMMIT}"

  echo "[+] creating '${container_name}' and configuring it as a manual machine"
  lxc launch "ubuntu:${distro}" "${container_name}" 2>&1 | sed -e 's/^/  lxd | /g'

  echo "- waiting for container IP to become available"
  while true; do
    host_ip=$(lxc list -c4 "${container_name}" | sed -r '/eth0/!d; s,.*(10\.[0-9.]+).*,\1,;')
    if [ ! -z "$host_ip" ]; then
      break
    fi
    sleep 1
  done

  # NOTE(achilleasa): it takes a few moments for everything to get mounted so
  # if the push fails sleep and retry.
  echo "- installing host key to container's authorized_keys file"
  while true; do
    lxc file push --mode 600 "${SSH_HOST_PUB_KEY}" "${container_name}/home/ubuntu/.ssh/authorized_keys" 2>/dev/null && break
    sleep 1
  done
  lxc exec "${container_name}" -- sh -c "chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys"

  # Flush any pre-existing entries for this IP
  ssh-keygen -R "${host_ip}" 2>/dev/null || true
  echo "- waiting for the host machine key to become available"
  while true; do
    host_keys=$(ssh-keyscan "${host_ip}" 2>/dev/null)
    if [ -z "${host_keys}" ]; then
      sleep 1 # it takes a bit for the host machine keys to be generated
      continue
    fi

    echo "- adding host IP ${host_ip} to known_hosts"
    echo ${host_keys} >> ~/.ssh/known_hosts
    break
  done

  echo "- adding manual cloud entry"
  echo "  manual-${distro}-amd64:" >> $clouds_file
  echo "    type: manual" >> $clouds_file
  echo "    endpoint: ${host_ip}" >> $clouds_file
done

### Run acceptance test
set +e
echo "Running test:"
timeout -s INT 5m ${TESTS_DIR}/assess_add_cloud.py $clouds_file $JUJU_BIN
EXITCODE=$?
exit $EXITCODE
