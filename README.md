# Juju CI Tests

The collection of jobs found in this repository make up the CI Run project.
CI Runs' aim is, when triggered by a commit to the juju repository is to:
  - Create s tarball snapshot of the codebase
  - Build binaries (for use in testing and as agents)
  - Update the testing streams
  - Run the unit tests
  - Run the suite of functional tests

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
