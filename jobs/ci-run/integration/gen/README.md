# gen-wire-tests

`gen-wire-tests` are generated wired up tests that are created by the tool
`tools/gen-wire-tests`. It reads in the `juju/juju` tests suite and wires them
up waiting for manual wire up to the integration runner.

None of the files inside the gen folder should be modified by hand and instead
should be changed in the template file within the tool.