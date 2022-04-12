  # even though we're a python lib, we're in a go path because of the way
  # the checkout setup runs and changing that will cause other projects to
  # break.
  cd ${GOPATH}/src/github.com/juju/python-libjuju
  # Fail if anything unexpected happens
  set -e

  sudo add-apt-repository ppa:deadsnakes/ppa
  sudo apt-get update -q
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git gcc make python3.5 python3.6 python3.7 python3.8 python3.9 python3-pip python3.5-dev python3.6-dev python3.7-dev python3.8-dev python3.9-dev python3.9-distutils

  set +e  # Will fail in reports gen if any errors occur
  set -o pipefail  # Need to error for make, not tees' success.

  pip3 install --user tox psutil || true
  export PATH="$HOME/.local/bin:$PATH"

  make test
  check_exit=$?

  set +o pipefail
  echo `date --rfc-3339=seconds` "ran make test"
