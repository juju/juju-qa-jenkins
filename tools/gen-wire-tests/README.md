# gen-wire-tests

The `gen-wire-tests` Go tool is used to generate the Jenkins integration tests
in `jobs/ci-run/integration/gen`. It requires one argument:
- The directory where the resulting yaml files will be written

You also need to provide a configuration file (usually `juju.config`) via stdin.

The tool reads the test suites from the Juju repo on github. To avoid API rate
limiting for unauthenticated requests, create an access token and set the env
var GH_TOKEN before running the tool. This is optional but recommended.

We suggest running it as follows:

```bash
cd ..
make gen-wire-tests
```

To run by hand, or the hard way:

```bash
cd tools/gen-wire-tests
cat juju.config | go run main.go \
  ../../jobs/ci-run/integration/gen
```

or

```bash
cd tools/gen-wire-tests
go build main.go
cat juju.config | ./main \
  ../../jobs/ci-run/integration/gen
```

If you are adding new test suites, you will also need to add a new job to
`jobs/ci-run/integration/integrationtests.yml`.
