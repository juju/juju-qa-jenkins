# Offline tests for the unit coverage upload block in
# jobs/ci-run/scripts/snippet_run-unit-tests.template.sh, exercised against
# the *rendered* unit-tests-amd64 job shell step so the test always tracks
# the production block rather than a rewritten copy. A stub curl emulates
# the collector; no real upload ever happens.

UPLOAD_STUB_NS="a1b2c3d4-namespace"
UPLOAD_STUB_URL="http://collector.invalid/unit/${UPLOAD_STUB_NS}/covdata"

# Render unit-tests-amd64 with JJB and extract the shell step containing the
# upload block (the cover branch writes cover.tar.gz).
upload_extract_step() {
    UPLOAD_XML_DIR=$(mktemp -d "${TEST_DIR}/upload-xml.XXX")
    UPLOAD_JJB_CONF=$(mktemp -d "${TEST_DIR}/upload-jjb.XXX")
    cat <<EOF >"${UPLOAD_JJB_CONF}/jenkins-jjb"
[job_builder]
ignore_cache=True
EOF
    UPLOAD_CACHE=$(mktemp -d /tmp/juju-qa-jenkins-jjb-cache.XXXXXX)
    if ! XDG_CACHE_HOME="${UPLOAD_CACHE}" jenkins-jobs --conf "${UPLOAD_JJB_CONF}" test -r "jobs/common:jobs/ci-run" unit-tests-amd64 -o "${UPLOAD_XML_DIR}" --config-xml >/dev/null 2>&1; then
        echo "FAIL: could not render unit-tests-amd64 with jenkins-jobs" >&2
        exit 1
    fi
    UPLOAD_STEP=$(mktemp "${TEST_DIR}/upload-step.XXX")
    XML_FILE="${UPLOAD_XML_DIR}/unit-tests-amd64/config.xml" OUT_FILE="${UPLOAD_STEP}" python3 - <<'PYEXTRACT'
import os
import xml.etree.ElementTree as ET

tree = ET.parse(os.environ["XML_FILE"])
cmds = [
    c.text
    for c in tree.getroot().iter("command")
    if c.text and "cover.tar.gz" in c.text
]
if len(cmds) != 1:
    raise SystemExit("expected exactly 1 step uploading cover.tar.gz, got %d" % len(cmds))
with open(os.environ["OUT_FILE"], "w") as f:
    f.write(cmds[0])
PYEXTRACT
    if [ "$(head -n 1 "${UPLOAD_STEP}")" != "#!/bin/bash" ]; then
        echo "FAIL: rendered unit-tests step does not start with #!/bin/bash" >&2
        exit 1
    fi
    if ! bash -n "${UPLOAD_STEP}"; then
        echo "FAIL: rendered unit-tests step has invalid bash syntax" >&2
        exit 1
    fi
}

# Temp workspace plus a PATH that shadows the commands the step runs before
# the upload, so only the upload block is exercised end to end.
upload_setup() {
    UPLOAD_WS=$(mktemp -d "${TEST_DIR}/upload-ws.XXX")
    UPLOAD_BIN=$(mktemp -d "${TEST_DIR}/upload-bin.XXX")

    for cmd in ssh-keyscan go2xunit; do
        printf '#!/bin/bash\nexit 0\n' >"${UPLOAD_BIN}/${cmd}"
        chmod +x "${UPLOAD_BIN}/${cmd}"
    done

    # make: for cover-test, populate GOCOVERDIR with the covdata files the
    # upload block checks for.
    cat >"${UPLOAD_BIN}/make" <<'MAKESTUB'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in
        GOCOVERDIR=*) gocoverdir="${arg#GOCOVERDIR=}" ;;
    esac
done
if [ "$1" = "cover-test" ] && [ -n "$gocoverdir" ]; then
    : >"$gocoverdir/covmeta.fixture"
    : >"$gocoverdir/covcounters.fixture"
fi
exit 0
MAKESTUB
    chmod +x "${UPLOAD_BIN}/make"

    # go: report amd64 for the arch gate, succeed otherwise.
    cat >"${UPLOAD_BIN}/go" <<'GOSTUB'
#!/bin/bash
if [ "$1" = "env" ] && [ "$2" = "GOARCH" ]; then
    echo amd64
fi
exit 0
GOSTUB
    chmod +x "${UPLOAD_BIN}/go"

    # The host-src-command builder wraps the step in
    # 'sudo su - $USER -c "$(...)"'; evaluate the inner payload directly.
    cat >"${UPLOAD_BIN}/sudo" <<'SUDOSTUB'
#!/bin/bash
# Skip leading 'su - <user> -c' arguments, then run the payload.
while [ "$1" = "su" ] || [ "$1" = "-" ] || [ "$1" = "$USER" ]; do
    shift
done
if [ "$1" = "-c" ]; then
    shift
    eval "$1"
    exit $?
fi
exec "$@"
SUDOSTUB
    chmod +x "${UPLOAD_BIN}/sudo"

    cat >"${UPLOAD_BIN}/curl" <<'CURLSTUB'
#!/bin/bash
# Stub curl: emulate the collector per UPLOAD_FAKE_MODE, capturing the body
# to the --output path and printing the status for --write-out.
body=""
out=""
status=200
rc=0
prev=""
for arg in "$@"; do
    case "$prev" in
        --output) out="$arg" ;;
    esac
    prev="$arg"
done
stderr_body=""
case "${UPLOAD_FAKE_MODE:-ok}" in
    ok)             body='{"stored":true}'; status=200; rc=0 ;;
    bad-request)    body="invalid tar header: unsupported layout"; status=400; rc=0 ;;
    empty-body)     body=""; status=400; rc=0 ;;
    leak)           body="upload rejected for ${UPLOAD_STUB_URL}: bad token hunter2"; status=400; rc=0 ;;
    leak-ns)        body="namespace ${UPLOAD_STUB_NS} is not registered"; status=400; rc=0 ;;
    leak-boundary)  body="$(printf 'x%.0s' $(seq 1 505))${UPLOAD_STUB_NS}"; status=400; rc=0 ;;
    leak-stderr)    body=""; stderr_body="curl: PUT ${UPLOAD_STUB_URL} failed for ${UPLOAD_STUB_NS}"; status=000; rc=7 ;;
    special-chars)  body="error: ${UPLOAD_STUB_URL} denied"; status=400; rc=0 ;;
    control-chars)  body="$(printf 'bad\x1b[31mvalue\x07\x01end')"; status=400; rc=0 ;;
    utf8)           body="erreur: donnees invalides — corps rejete"; status=400; rc=0 ;;
    big)            body=$(printf 'x%.0s' $(seq 1 2000)); status=400; rc=0 ;;
    transport-err)  body=""; stderr_body="curl: (7) Failed to connect to ${UPLOAD_STUB_URL}"; status=000; rc=7 ;;
esac
[ -n "$out" ] && printf '%s' "$body" >"$out"
[ -n "$stderr_body" ] && printf '%s' "$stderr_body" >&2
printf '%s' "$status"
exit "$rc"
CURLSTUB
    chmod +x "${UPLOAD_BIN}/curl"
}

# upload_run <mode> runs the rendered step with the curl stub in <mode>,
# capturing combined output and the exit code.
upload_run() {
    upload_rc_file=$(mktemp "${TEST_DIR}/upload-rc.XXX")
    upload_out_file=$(mktemp "${TEST_DIR}/upload-out.XXX")
    # -u xtrace: make cover-test runs with `set -x` on, so the mktemp -d
    # assignment of GOCOVERDIR is traced; recover the exact directory below.
    (
        export PATH="${UPLOAD_BIN}:${PATH}"
        export WORKSPACE="${UPLOAD_WS}"
        export GOPATH="${UPLOAD_WS}/.go"
        export JUJU_SRC_PATH="${UPLOAD_WS}"
        export TEST_TIMEOUT=600
        export COVERAGE_ENABLED=true
        export UNIT_COVERAGE_COLLECT_URL="${UPLOAD_STUB_URL}"
        export UPLOAD_FAKE_MODE="$1"
        export UPLOAD_STUB_URL
        export UPLOAD_STUB_NS
        export HOME="${UPLOAD_WS}"
        mkdir -p "${UPLOAD_WS}/.ssh"
        mkdir -p "${GOPATH}/bin"
        # go2xunit is invoked by absolute path; link the stub there.
        ln -sf "${UPLOAD_BIN}/go2xunit" "${GOPATH}/bin/go2xunit"
        cd "${UPLOAD_WS}" || exit 1
        bash "${UPLOAD_STEP}" || echo "$?" >"${upload_rc_file}"
        true
    ) >"${upload_out_file}" 2>&1
    # `... || echo rc` captures a failing step's status while `true` keeps
    # the substitution's exit status zero so the harness's `set -e` does not
    # abort before the assertions run.
    UPLOAD_OUTPUT=$(cat "${upload_out_file}")
    UPLOAD_RC=0
    if [ -s "${upload_rc_file}" ]; then
        UPLOAD_RC=$(cat "${upload_rc_file}")
    fi
    UPLOAD_GOCOVERDIR=$(sed -n 's/^[+ ]*GOCOVERDIR=//p' "${upload_out_file}" | head -n 1)
}

upload_expect_fail_with() {
    upload_desc="$1"
    upload_want="$2"
    if [ "${UPLOAD_RC}" -eq 0 ]; then
        echo "FAIL: ${upload_desc}: expected failure, step succeeded" >&2
        exit 1
    fi
    if ! printf '%s' "${UPLOAD_OUTPUT}" | grep -q "${upload_want}"; then
        echo "FAIL: ${upload_desc}: expected diagnostic containing '${upload_want}':" >&2
        printf '%s\n' "${UPLOAD_OUTPUT}" >&2
        exit 1
    fi
    echo "PASS: ${upload_desc}"
}

test_coverage_upload() {
    upload_extract_step
    upload_setup

    upload_run bad-request
    upload_expect_fail_with "HTTP 400 with a body reports status and excerpt" "http_status=400"
    if ! printf '%s' "${UPLOAD_OUTPUT}" | grep -q "unsupported layout"; then
        echo "FAIL: 400 diagnostic lost the response body excerpt:" >&2
        printf '%s\n' "${UPLOAD_OUTPUT}" >&2
        exit 1
    fi
    echo "PASS: HTTP 400 diagnostic includes the response body excerpt"

    upload_run empty-body
    upload_expect_fail_with "HTTP 400 with an empty body is explicit" "collector response body is empty"

    upload_run transport-err
    upload_expect_fail_with "transport failure retains the curl status" "curl_rc=7"

    upload_run ok
    if [ "${UPLOAD_RC}" -ne 0 ]; then
        echo "FAIL: HTTP 200 upload failed:" >&2
        printf '%s\n' "${UPLOAD_OUTPUT}" >&2
        exit 1
    fi
    if printf '%s' "${UPLOAD_OUTPUT}" | grep -q "stored"; then
        echo "FAIL: successful upload dumped the response body" >&2
        exit 1
    fi
    echo "PASS: HTTP 200 upload succeeds without dumping the body"

    upload_run leak
    if printf '%s' "${UPLOAD_OUTPUT}" | grep -q "collector.invalid/unit/covdata"; then
        echo "FAIL: diagnostic leaked the collection URL:" >&2
        printf '%s\n' "${UPLOAD_OUTPUT}" >&2
        exit 1
    fi
    echo "PASS: diagnostic redacts the collection URL"

    upload_run leak-ns
    if printf '%s' "${UPLOAD_OUTPUT}" | grep -q "a1b2c3d4-namespace"; then
        echo "FAIL: diagnostic leaked the standalone namespace:" >&2
        printf '%s\n' "${UPLOAD_OUTPUT}" >&2
        exit 1
    fi
    echo "PASS: standalone namespace is redacted"

    upload_run leak-boundary
    if printf '%s' "${UPLOAD_OUTPUT}" | grep -q "a1b2c3d4-namespace"; then
        echo "FAIL: namespace leaked across the truncation boundary:" >&2
        printf '%s\n' "${UPLOAD_OUTPUT}" >&2
        exit 1
    fi
    echo "PASS: redaction precedes truncation (no partial namespace at the boundary)"

    upload_run leak-stderr
    if printf '%s' "${UPLOAD_OUTPUT}" | grep -q "collector.invalid"; then
        echo "FAIL: curl stderr leaked the collection URL:" >&2
        printf '%s\n' "${UPLOAD_OUTPUT}" >&2
        exit 1
    fi
    echo "PASS: curl stderr is captured and sanitised"

    upload_run control-chars
    if printf '%s' "${UPLOAD_OUTPUT}" | grep -qP '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'; then
        echo "FAIL: control characters reached the log:" >&2
        printf '%s\n' "${UPLOAD_OUTPUT}" >&2
        exit 1
    fi
    echo "PASS: control characters and escape sequences are stripped"

    upload_run utf8
    if [ "${UPLOAD_RC}" -eq 0 ]; then
        echo "FAIL: utf8 case should fail (HTTP 400)" >&2
        exit 1
    fi
    if ! printf '%s' "${UPLOAD_OUTPUT}" | grep -q "donnees invalides"; then
        echo "FAIL: UTF-8 response was mangled or dropped:" >&2
        printf '%s\n' "${UPLOAD_OUTPUT}" >&2
        exit 1
    fi
    echo "PASS: UTF-8 responses are handled safely"

    upload_run big
    upload_out_len=$(printf '%s' "${UPLOAD_OUTPUT}" | wc -c)
    if [ "${upload_out_len}" -gt 2500 ]; then
        echo "FAIL: diagnostic is not bounded (${upload_out_len} bytes)" >&2
        exit 1
    fi
    echo "PASS: long collector responses are bounded"

    # Literal matching: a URL containing glob/regex-significant characters
    # must be redacted as a fixed string, not treated as a pattern.
    UPLOAD_STUB_NS='tok+[abc].*x'
    UPLOAD_STUB_URL="http://collector.invalid/unit/tok+[abc].*x/covdata"
    upload_run leak
    if printf '%s' "${UPLOAD_OUTPUT}" | grep -qF 'tok+[abc].*x'; then
        echo "FAIL: glob/regex-significant namespace was not redacted literally:" >&2
        printf '%s\n' "${UPLOAD_OUTPUT}" >&2
        exit 1
    fi
    echo "PASS: glob/regex-significant URL characters are matched literally"

    # A pre-existing test failure must stay fatal after a successful upload.
    UPLOAD_STUB_NS="a1b2c3d4-namespace"
    UPLOAD_STUB_URL="http://collector.invalid/unit/${UPLOAD_STUB_NS}/covdata"
    cat >"${UPLOAD_BIN}/make" <<'MAKEFAIL'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in
        GOCOVERDIR=*) gocoverdir="${arg#GOCOVERDIR=}" ;;
    esac
done
if [ "$1" = "cover-test" ] && [ -n "$gocoverdir" ]; then
    : >"$gocoverdir/covmeta.fixture"
    : >"$gocoverdir/covcounters.fixture"
fi
exit 3
MAKEFAIL
    chmod +x "${UPLOAD_BIN}/make"
    upload_run ok
    if [ "${UPLOAD_RC}" -ne 3 ]; then
        echo "FAIL: successful upload masked the test failure (rc ${UPLOAD_RC}, want 3)" >&2
        exit 1
    fi
    echo "PASS: successful upload does not mask a failing test run"

    # If the sanitiser itself fails, emit only the fixed safe message and
    # keep the upload failure fatal; never fall back to raw content.
    cat >"${UPLOAD_BIN}/python3" <<'PYFAIL'
#!/bin/bash
exit 1
PYFAIL
    chmod +x "${UPLOAD_BIN}/python3"
    upload_run bad-request
    if [ "${UPLOAD_RC}" -eq 0 ]; then
        echo "FAIL: sanitiser failure should keep the upload failure fatal" >&2
        exit 1
    fi
    if ! printf '%s' "${UPLOAD_OUTPUT}" | grep -q "http_status=400"; then
        echo "FAIL: sanitiser failure lost the status diagnostic:" >&2
        printf '%s\n' "${UPLOAD_OUTPUT}" >&2
        exit 1
    fi
    if printf '%s' "${UPLOAD_OUTPUT}" | grep -q "unsupported layout"; then
        echo "FAIL: sanitiser failure fell back to raw content:" >&2
        printf '%s\n' "${UPLOAD_OUTPUT}" >&2
        exit 1
    fi
    echo "PASS: sanitiser failure emits only the safe message and stays fatal"

    # Archive layout: the collector rejects directory entries ("invalid file
    # type: ./"), so the archive must contain only regular files with bare
    # covmeta.*/covcounters.* names.
    rm -f "${UPLOAD_BIN}/python3"
    cat >"${UPLOAD_BIN}/make" <<'MAKEMANY'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in
        GOCOVERDIR=*) gocoverdir="${arg#GOCOVERDIR=}" ;;
    esac
done
if [ "$1" = "cover-test" ] && [ -n "$gocoverdir" ]; then
    : >"$gocoverdir/covmeta.one"
    : >"$gocoverdir/covmeta.two"
    : >"$gocoverdir/covcounters.one"
    : >"$gocoverdir/covcounters.two"
    : >"$gocoverdir/unrelated.txt"
    mkdir -p "$gocoverdir/subdir"
    : >"$gocoverdir/subdir/covmeta.nested"
fi
exit 0
MAKEMANY
    chmod +x "${UPLOAD_BIN}/make"
    upload_run ok
    if [ "${UPLOAD_RC}" -ne 0 ]; then
        echo "FAIL: upload with multiple coverage files failed:" >&2
        printf '%s\n' "${UPLOAD_OUTPUT}" >&2
        exit 1
    fi
    if [ -z "${UPLOAD_GOCOVERDIR}" ]; then
        echo "FAIL: could not recover GOCOVERDIR from the step output" >&2
        exit 1
    fi
    upload_entries=$(tar -tzf "${UPLOAD_WS}/cover.tar.gz")
    upload_want_entries=$(printf '%s\n' \
        "covcounters.one" "covcounters.two" "covmeta.one" "covmeta.two" | sort)
    if [ "$(printf '%s\n' "${upload_entries}" | sort)" != "${upload_want_entries}" ]; then
        echo "FAIL: archive entries differ from the bare coverage files:" >&2
        printf '%s\n' "${upload_entries}" >&2
        exit 1
    fi
    echo "PASS: archive contains every covmeta.*/covcounters.* file and nothing else"
    if printf '%s\n' "${upload_entries}" | grep -qE '(^|/)unrelated\.txt$|(^|/)subdir(/|$)'; then
        echo "FAIL: unrelated files or subdirectories were archived:" >&2
        printf '%s\n' "${upload_entries}" >&2
        exit 1
    fi
    echo "PASS: unrelated files and subdirectories are not archived"
    upload_types=$(tar -tvzf "${UPLOAD_WS}/cover.tar.gz" | awk '{print $1}')
    if printf '%s\n' "${upload_types}" | grep -qv '^-'; then
        echo "FAIL: archive contains a non-regular-file entry:" >&2
        printf '%s\n' "${upload_types}" >&2
        exit 1
    fi
    echo "PASS: every archive entry is a regular file"
    if printf '%s\n' "${upload_entries}" | grep -qE '^\./|/|^~'; then
        echo "FAIL: archive contains directory entries, './' prefixes or absolute paths:" >&2
        printf '%s\n' "${upload_entries}" >&2
        exit 1
    fi
    echo "PASS: no directory entries, './' prefixes or absolute paths"

    # Missing coverage data fails before upload.
    cat >"${UPLOAD_BIN}/make" <<'MAKENOCOUNTERS'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in
        GOCOVERDIR=*) gocoverdir="${arg#GOCOVERDIR=}" ;;
    esac
done
if [ "$1" = "cover-test" ] && [ -n "$gocoverdir" ]; then
    : >"$gocoverdir/covmeta.only"
fi
exit 0
MAKENOCOUNTERS
    chmod +x "${UPLOAD_BIN}/make"
    rm -f "${UPLOAD_WS}/cover.tar.gz"
    upload_run ok
    upload_expect_fail_with "missing counter files fails before upload" "unit coverage data is missing"
    if [ -e "${UPLOAD_WS}/cover.tar.gz" ]; then
        echo "FAIL: archive was created despite missing counter files" >&2
        exit 1
    fi
    echo "PASS: no archive is created when coverage data is missing"

    cat >"${UPLOAD_BIN}/make" <<'MAKENOMETA'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in
        GOCOVERDIR=*) gocoverdir="${arg#GOCOVERDIR=}" ;;
    esac
done
if [ "$1" = "cover-test" ] && [ -n "$gocoverdir" ]; then
    : >"$gocoverdir/covcounters.only"
fi
exit 0
MAKENOMETA
    chmod +x "${UPLOAD_BIN}/make"
    upload_run ok
    upload_expect_fail_with "missing metadata files fails before upload" "unit coverage data is missing"

    # Archive failure is fatal and prevents upload.
    cat >"${UPLOAD_BIN}/make" <<'MAKEGONE'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in
        GOCOVERDIR=*) gocoverdir="${arg#GOCOVERDIR=}" ;;
    esac
done
if [ "$1" = "cover-test" ] && [ -n "$gocoverdir" ]; then
    # Directory listing still works without the search bit, so the
    # covmeta/covcounters existence checks pass; only the archive step's
    # cd fails.
    : >"$gocoverdir/covmeta.gone"
    : >"$gocoverdir/covcounters.gone"
    chmod 0400 "$gocoverdir"
fi
exit 0
MAKEGONE
    chmod +x "${UPLOAD_BIN}/make"
    rm -f "${UPLOAD_WS}/cover.tar.gz"
    upload_run ok
    upload_expect_fail_with "an unsearchable GOCOVERDIR fails the archive step" "failed to archive unit coverage data"
    if [ -e "${UPLOAD_WS}/cover.tar.gz" ]; then
        echo "FAIL: archive exists after the archive step failed" >&2
        exit 1
    fi
    echo "PASS: archive failure prevents upload"

    cat >"${UPLOAD_BIN}/make" <<'MAKETARFAIL'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in
        GOCOVERDIR=*) gocoverdir="${arg#GOCOVERDIR=}" ;;
    esac
done
if [ "$1" = "cover-test" ] && [ -n "$gocoverdir" ]; then
    : >"$gocoverdir/covmeta.tarfail"
    : >"$gocoverdir/covcounters.tarfail"
fi
exit 0
MAKETARFAIL
    chmod +x "${UPLOAD_BIN}/make"
    cat >"${UPLOAD_BIN}/tar" <<'TARSTUB'
#!/bin/bash
exit 1
TARSTUB
    chmod +x "${UPLOAD_BIN}/tar"
    upload_run ok
    upload_expect_fail_with "a failing tar fails the archive step" "failed to archive unit coverage data"
    rm -f "${UPLOAD_BIN}/tar"
}

test_coverage_upload_suite() {
    if [ "$(skip 'test_coverage_upload')" ]; then
        echo "==> TEST SKIPPED: coverage upload tests"
        return
    fi

    (
        set_verbosity

        cd .. || exit

        run "test_coverage_upload"
    )
}
