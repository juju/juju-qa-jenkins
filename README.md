# Juju CI Tests

The collection of jobs found in this repository make up the CI Run project.
CI Runs' aim is, when triggered by a commit to the juju repository is to:
  - Create s tarball snapshot of the codebase
  - Build binaries (for use in testing and as agents)
  - Update the testing streams
  - Run the unit tests
  - Run the suite of functional tests

