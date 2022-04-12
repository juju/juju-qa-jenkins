yaml_check() {
  FILE="${1}"

  py=$(cat <<EOF
import yaml, sys

def path(loader, tag_suffix, node):
  tags = [u'!include-raw:', u'!include:', u'!include-raw-escape:']
  if tag_suffix not in tags:
    raise Exception('unknown tag: {}, expected: {}'.format(tag_suffix, tags))
  return 'input-raw'

yaml.add_multi_constructor('', path)
yaml.load(sys.stdin, Loader=yaml.Loader)
EOF
)

  OUT=$(python3 -c "${py}" 2>&1 < "${FILE}" || true)
  if [ -n "${OUT}" ]; then
    echo ""
    echo "$(red 'Found some issues:')"
    echo "${OUT}"
    exit 1
  fi
}

run_yaml_check() {
  FILES="${2}"

  echo "$FILES" | while IFS= read -r line; do yaml_check "${line}"; done
}

run_yaml_deadcode() {
  OUT=$(go run tests/suites/static_analysis/deadcode/main.go "$(pwd)" <<EOF 2>&1 || true
files:
  skip:
    - .github/workflows/static-analysis.yml
    - .github/workflows/local-deployment.yml
jobs:
  ignore:
    - apt-update-slaves
    - CI-BuildJuju
    - CI-GatingTests
    - CI-ProvingGroundsTests
    - clean-lxd-environments
    - clean-maas-environments
    - clean-workspaces
    - github-juju-check-jobs
    - github-juju-merge-jobs
    - github-juju-pylibjuju-jobs
    - github-integration-tests-pylibjuju
    - github-mgo-check-jobs
    - github-mgo-merge-jobs
    - github-prs
    - sync-ntp
    - z-clean-azure
    - z-clean-microk8s
    - z-clean-prodstack
    - z-clean-resources-aws
    - z-clean-resources-gce
    - z-clean-resources-gke
    - z-clean-resources-aks
    - z-clean-resources-equinix
    - z-clean-resources-joyent
    - z-clean-resources-oracle
    - z-clean-resources-rackspace
    - z-clean-resources-vsphere
    - z-clean-resources-vsphere-boston
    - z-clean-resources-windows
    - run-unit-tests-lxd

    # TODO (stickupkid): The followng jobs seem to be orphan jobs with in the
    # jenkins suite. We should clean them up to ensure that they do run, or 
    # are removed.
    #
    # nw-deploy-lxd-profile-bundle-lxd* should be removed once proved in 
    # deploy tests.
    - nw-deploy-lxd-profile-bundle-lxd
    - nw-deploy-lxd-profile-bundle-lxd-openstack
    - nw-caas-deploy-charms-kubernetes-core-iaas-controller
    - nw-caas-deploy-charms-microk8s-iaas-controller
    - nw-deploy-bionic-amd64-manual
    - nw-upgrade-lxd-profile-lxd
    - integration-tests
    - public-clouds
    - lxd-src-command-focal-base
    - test-manual-multijob
    - z-clean-resources-eks
    - github-juju-experimental-check-jobs
    - juju-integration-deploy
    - nw-deploy-focal-amd64-lxd
    - get-s3-build-payload-exotic
    - integration-test-runner-focal
    - z-clean-resources-ecr
EOF
)
  if [ -n "${OUT}" ]; then
    echo ""
    echo "$(red 'Found some issues:')"
    echo "${OUT}"
    exit 1
  fi
}

run_yaml_simplify() {
  OUT=$(go run tests/suites/static_analysis/simplify/main.go "$(pwd)" <<EOF 2>&1 || true
files:
  skip:
    - .github/workflows/static-analysis.yml
    - .github/workflows/local-deployment.yml
jobs:
  ignore:
    # TODO (stickupkid): Clean these commands up and simplify the following jobs
    # so that they don't require a multi-job for no reason.
    - RunFunctionalTests-arm64:FunctionalTestsarm64
    - RunFunctionalTests-ppc64el:FunctionalTestsarm64
    - RunFunctionalTests-s390x:FunctionalTestss390x
    - SimpleStreams:GenerateSimpleStreams
    - ci-run:building
    - github-mgo-check-jobs:github-mgo-check-jobs
    - github-mgo-merge-jobs:github-mgo-merge-jobs
    - github-juju-merge-jobs:github-juju-merge-jobs
    - github-juju-pylibjuju-jobs:github-juju-pylibjuju-jobs
    - integration-tests:IntegrationTests
    - Gating-RunFunctionalTests-arm64:FunctionalTestsarm64
    - Gating-RunFunctionalTests-ppc64el:FunctionalTestsarm64
    - Gating-RunFunctionalTests-s390x:FunctionalTestss390x
    - test-cli-multijob:IntegrationTests-cli
    - test-bootstrap-multijob:IntegrationTests-bootstrap
    - github-juju-experimental-check-jobs:github-juju-check-jobs
    - CI-BuildJuju:Packaging
    - test-caasadmission-multijob:IntegrationTests-caasadmission
    - test-upgrade-multijob:IntegrationTests-upgrade
    - test-ck-multijob:IntegrationTests-ck
    - test-sidecar-multijob:IntegrationTests-sidecar
EOF
)
  if [ -n "${OUT}" ]; then
    echo ""
    echo "$(red 'Found some issues:')"
    echo "${OUT}"
    exit 1
  fi
}

test_static_analysis_yaml() {
  if [ "$(skip 'test_static_analysis_yaml')" ]; then
      echo "==> TEST SKIPPED: static yaml analysis"
      return
  fi

  (
    set_verbosity

    cd .. || exit

    FILES=$(find ./* -name '*.yml')

    # YAML static analysis
    if which python >/dev/null 2>&1; then
      run "run_yaml_check" "${FILES}"
    else
      echo "python not found, yaml static analysis disabled"
    fi

    # YAML deadcode elimiation
    if which go >/dev/null 2>&1; then
      run "run_yaml_deadcode"
    else
      echo "go not found, yaml deadcode disabled"
    fi

    # YAML simplify
    if which go >/dev/null 2>&1; then
      run "run_yaml_simplify"
    else
      echo "go not found, yaml simplify disabled"
    fi
  )
}
