# gen-wire-tests

The `gen-wire-tests` Go tool generates Jenkins integration test job
definitions in `jobs/ci-run/integration/gen`.

It is split into two commands:

- `collect` — fetches test suite and subtask information from the Juju
  GitHub repo for each supported branch and saves it locally as YAML.
- `generate` — reads those saved YAML files and a config file (via
  stdin) to produce the Jenkins job definition YAML files.

The `collect` output files (`3.6.yaml`, `main.yaml`) are committed to
this repository so that `generate` can be run without GitHub access or
API token.

## Usage

### collect

Run this when test suites in the Juju repo have changed. Requires a
GitHub token to avoid API rate limiting.

```bash
export GH_TOKEN=your_token
go run ./tools/gen-wire-tests/main.go collect ./tools/gen-wire-tests
```

Or via make:

```bash
GH_TOKEN=your_token make collect-wire-tests
```

### generate

Run this when `juju.config` has changed or after a `collect`. No
GitHub access required.

```bash
cat tools/gen-wire-tests/juju.config | \
  go run ./tools/gen-wire-tests/main.go generate \
    ./tools/gen-wire-tests \
    ./jobs/ci-run/integration/gen
```

Or via make (recommended):

```bash
make gen-wire-tests
```

## Configuration

The config file (`juju.config`) is passed via stdin to `generate`.
It controls:

- `skip-all` — suites to ignore entirely.
- `skip-lxd`, `skip-aws`, `skip-google`, `skip-azure`,
  `skip-microk8s` — suites (or `suite-task` pairs) to exclude from a
  specific cloud.
- `skip-subtasks` — individual subtasks to exclude from all clouds.
- `prevent-split` — suites whose subtasks should not be split into
  separate jobs.
- `ephemeral` — suites that run on ephemeral infrastructure.
- `cross-cloud` — suites that run cross-cloud jobs.
- `timeout` — per-suite, per-task timeout overrides (minutes).
- `introduced` — minimum Juju version a suite or task requires.
- `removed` — maximum Juju version a suite or task exists in.

If you are adding new test suites you will also need to add a
corresponding job to `jobs/ci-run/integration/integrationtests.yml`.