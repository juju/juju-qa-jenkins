# gen-wire-tests

The `gen-wire-tests` Go tool is used to generate the Jenkins integration tests
in `jobs/ci-run/integration/gen`. It requires two arguments:
- The path to the Juju `tests/suites` directory
- The directory where the resulting yaml files will be written

You also need to provide a configuration file (usually `juju.config`) via stdin.

We suggest running it as follows:

```bash
cd ..
make gen-wire-tests
```

To run by hand, or the hard way:

```bash
cd tools/gen-wire-tests
cat juju.config | go run main.go <jujuroot>/tests/suites \
  ../../jobs/ci-run/integration/gen <version of juju>
```

or

```bash
cd tools/gen-wire-tests
go build main.go
cat juju.config | ./main <jujuroot>/tests/suites \
  ../../jobs/ci-run/integration/gen <version of juju>
```

where `<jujuroot>` is the path to the Juju source tree on your local machine.

If you are adding new test suites, you will also need to add a new job to
`jobs/ci-run/integration/integrationtests.yml`.
