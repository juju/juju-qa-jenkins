#!/bin/bash
set -eux

# Make sure github is known to us.
ssh-keyscan github.com >> $HOME/.ssh/known_hosts

echo TEST_TIMEOUT=$TEST_TIMEOUT

cd ${{JUJU_SRC_PATH}}
# when running inside a privileged container, snapd fails because udevd isn't
# running, but on the second occurance it is.
# see: https://github.com/lxc/lxd/issues/4308
make install-mongo-dependencies || true
make setup-lxd || true

# Disable JS support as juju-mongodb doesn't support it.
export JUJU_NOTEST_MONGOJS=1

set +e  # Will fail in reports gen if any errors occur
set -o pipefail  # Need to error for make, not tees' success.
TEST_TYPE="{GOTEST_TYPE}"
if [[ "${{TEST_TYPE}}" == "cover" && "${{COVERAGE_ENABLED:-false}}" != "true" ]]; then
  TEST_TYPE="xunit-report"
fi
if [[ "${{TEST_TYPE}}" == "cover" && "$(go env GOARCH)" != "amd64" ]]; then
  echo "coverage is only collected by the amd64 unit-test job"
  TEST_TYPE="xunit-report"
fi

if [[ "${{TEST_TYPE}}" == "race" ]]; then
    if [ "$(make -q race-test > /dev/null 2>&1 || echo $?)" -eq 2 ]; then
        # if we don't have a race-test target, use go test.
        go test -v -race -test.timeout=${{TEST_TIMEOUT}} ./... | tee ${{WORKSPACE}}/go-unittest.out
        exit_code=$?
    else
        JUJU_GOMOD_MODE=vendor make race-test CGO_LDFLAGS="{CGO_LDFLAGS}" VERBOSE_CHECK=1 TEST_TIMEOUT=${{TEST_TIMEOUT}} | tee ${{WORKSPACE}}/go-unittest.out
        exit_code=$?
    fi
elif [[ "${{TEST_TYPE}}" == "xunit-report" ]]; then
    JUJU_GOMOD_MODE=vendor make test VERBOSE_CHECK=1 FUZZ_CHECK={FUZZ_CHECK} TEST_TIMEOUT=${{TEST_TIMEOUT}} | tee ${{WORKSPACE}}/go-unittest.out
    exit_code=$?
elif [[ "${{TEST_TYPE}}" == "cover" ]]; then
    export GOCOVERDIR=`mktemp -d`
    JUJU_GOMOD_MODE=vendor make cover-test VERBOSE_CHECK=1 FUZZ_CHECK={FUZZ_CHECK} TEST_TIMEOUT=${{TEST_TIMEOUT}} GOCOVERDIR=${{GOCOVERDIR}} | tee ${{WORKSPACE}}/go-unittest.out
    exit_code=$?
    upload_xtrace=$(set +o | grep -q 'set -o xtrace' && echo on || echo off)
    set +x
    if [[ -n "${{UNIT_COVERAGE_COLLECT_URL:-}}" ]]; then
        if ! compgen -G "${{GOCOVERDIR}}/covmeta.*" >/dev/null || ! compgen -G "${{GOCOVERDIR}}/covcounters.*" >/dev/null; then
            echo "unit coverage data is missing" >&2
            if [[ "${{upload_xtrace}}" == "on" ]]; then set -x; fi
            exit 1
        fi
        if ! (
            cd "${{GOCOVERDIR}}" &&
            tar -czf "${{WORKSPACE}}/cover.tar.gz" \
                covmeta.* covcounters.*
        ); then
            echo "failed to archive unit coverage data" >&2
            if [[ "${{upload_xtrace}}" == "on" ]]; then set -x; fi
            exit 1
        fi
        upload_body=$(mktemp)
        upload_stderr=$(mktemp)
        http_status=$(curl --show-error --retry 3 --silent \
            --output "${{upload_body}}" --write-out '%{{http_code}}' \
            --upload-file "${{WORKSPACE}}/cover.tar.gz" \
            "${{UNIT_COVERAGE_COLLECT_URL}}" 2>"${{upload_stderr}}")
        upload_rc=$?
        if [[ ${{upload_rc}} -ne 0 || ! "${{http_status}}" =~ ^2 ]]; then
            echo "failed to upload unit coverage data (http_status=${{http_status:-unavailable}} curl_rc=${{upload_rc}})" >&2
            # Redact before truncating: replace the full URL, its namespace
            # and any embedded credentials with fixed tokens (literal, not
            # regex), strip control characters, then bound each excerpt to
            # 512 bytes. On any sanitiser failure emit a fixed safe message
            # and keep the upload failure fatal.
            sanitized=$( \
                UPLOAD_BODY="${{upload_body}}" \
                UPLOAD_STDERR="${{upload_stderr}}" \
                UPLOAD_URL="${{UNIT_COVERAGE_COLLECT_URL}}" \
                python3 - <<'SANITISE'
import os
import sys

url = os.environ["UPLOAD_URL"]
creds = ""
netloc = url.split("://", 1)[-1].split("/", 1)[0]
if "@" in netloc:
    creds = netloc.rsplit("@", 1)[0]

# Redact the full URL plus each path/query segment long enough to act as a
# namespace or token, so a standalone namespace is caught wherever it
# appears. Short structural segments (scheme, host labels) are left alone.
secrets = [url]
for segment in url.split("://", 1)[-1].replace("?", "/").replace("&", "/").replace("=", "/").split("/"):
    if len(segment) >= 8:
        secrets.append(segment)
if creds:
    secrets.append(creds)

def sanitise(path):
    try:
        with open(path, "rb") as fh:
            text = fh.read().decode("utf-8", "replace")
    except OSError:
        return ""
    for secret in secrets:
        text = text.replace(secret, "[REDACTED]")
    text = "".join(ch if (ch == "\n" or not ord(ch) < 0x20 and ord(ch) != 0x7f) else " " for ch in text)
    return text.strip()[:512]

body = sanitise(os.environ["UPLOAD_BODY"])
stderr = sanitise(os.environ["UPLOAD_STDERR"])
parts = []
if body:
    parts.append("response: " + body)
if stderr:
    parts.append("curl stderr: " + stderr)
sys.stdout.write("\n".join(parts))
SANITISE
            ) || sanitized=""
            if [[ -z "${{sanitized// /}}" ]]; then
                echo "collector response body is empty" >&2
            else
                printf 'collector diagnostics (sanitised, first 512 bytes each):\n%s\n' "${{sanitized}}" >&2
            fi
            if [[ "${{upload_xtrace}}" == "on" ]]; then set -x; fi
            rm -f "${{upload_body}}" "${{upload_stderr}}"
            exit 1
        fi
        if [[ "${{upload_xtrace}}" == "on" ]]; then set -x; fi
        rm -f "${{upload_body}}" "${{upload_stderr}}"
    fi
fi
set +o pipefail

${{GOPATH}}/bin/go2xunit -fail -input ${{WORKSPACE}}/go-unittest.out -output ${{WORKSPACE}}/tests.xml
# Sometimes go2xunit doesn't exit non-zero when we would expect it to. Force
# this based on make result.
exit $exit_code
