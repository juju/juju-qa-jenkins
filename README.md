# Juju CI Tests

The collection of jobs found in this repository make up the CI Run project.
CI Runs' aim is, when triggered by a commit to the juju repository is to:

- Create a tarball snapshot of the codebase
- Build binaries (for use in testing and as agents)
- Update the testing streams
- Run the unit tests
- Run the suite of integration tests

The integration tests themselves are not in this repo, they are in
`github.com/juju/juju/tests/suites`. This repo contains the informaion Jekins
needs to run the tests.

## Changing the tests

To change which clouds and which versions the tests run on, edit
`./tools/gen-wire-tests/juju.config`. To change which tests are run,
edit `./jobs/ci-run/integration/integrationtests.yml`.

To build the job descriptions run:

```
export GH_TOKEN=<your github token>
JUJU_REPO_PATH="<juju-repo-on-branch-to-generate-jobs-from>" make gen-wire-tests
```

## Uploading to Jenkins

To push, you need to be on the Canonical VPN and have your authentication token ready. If you don't have any, create an
[API Token on jenkins](https://www.jenkins.io/doc/book/system-administration/authenticating-scripted-clients/)

Then setup the environment variables:

```shell
export JENKINS_USER=<your username>
export JENKINS_ACCESS_TOKEN=<your access token>
```

Check that everything is working with:

```bash
make test-push
```

And push to https://jenkins.juju.canonical.com/ with:

```bash
make push
```

## Run on Noble 24.04

This is a workaround for issues encountered when running the push (and other make targets) script on ubuntu noble, related to python3 being 3.12 and jenkins-jjb being broken by it.

The workaround consist of basically installing python3.11 through a ppa and changing the python base path on the Makefile by hand before re-creating the virtual env and re-running the targets:

```
sudo add-apt-repository ppa:deadsnakes/ppa
sudo apt-get update && sudo apt-get install python3.11-venv
rm -rf venv/
# fix temporary the python3 --> python3.11
vim Makefile
make ensure-venv
# fix temporary the python3.11 --> python3
# python_base_path = $(shell which python3.11)
vim Makefile
make test-push
```
