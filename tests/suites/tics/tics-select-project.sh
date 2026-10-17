# Offline tests for the production TICS branch/project selection logic in
# jobs/ci-run/scripts/tics-select-project.sh, exercised against a temporary
# local git repository with representative remote-tracking refs.

tics_setup_repo() {
    TICS_REPO=$(mktemp -d "${TEST_DIR}/tics-repo.XXX")
    git -C "${TICS_REPO}" init -q -b init
    git -C "${TICS_REPO}" config user.email tics-test@example.com
    git -C "${TICS_REPO}" config user.name "TICS Test"

    # Plumbing-only fixture (the harness runs under sh, where porcelain
    # checkout -b behaves differently): a shared base commit, then one unique
    # tip commit per branch (base -> c3.6, base -> c4.0, ...). 3.6 and 4.1
    # are the supported branches; 4.0 and main exist so that revisions unique
    # to unsupported branches are exercised.
    tics_commit() {
        # tics_commit <parent|-> <message>
        tics_parent_args=""
        if [ "$1" != "-" ]; then
            tics_parent_args="-p $1"
        fi
        tics_tree=$(git -C "${TICS_REPO}" mktree </dev/null)
        # shellcheck disable=SC2086
        git -C "${TICS_REPO}" commit-tree "${tics_tree}" ${tics_parent_args} -m "$2"
    }

    TICS_BASE=$(tics_commit - base)
    TICS_C36=$(tics_commit "${TICS_BASE}" c36)
    TICS_C40=$(tics_commit "${TICS_BASE}" c40)
    TICS_C41=$(tics_commit "${TICS_BASE}" c41)
    TICS_CMAIN=$(tics_commit "${TICS_BASE}" cmain)

    git -C "${TICS_REPO}" update-ref refs/heads/3.6 "${TICS_C36}"
    git -C "${TICS_REPO}" update-ref refs/heads/4.0 "${TICS_C40}"
    git -C "${TICS_REPO}" update-ref refs/heads/4.1 "${TICS_C41}"
    git -C "${TICS_REPO}" update-ref refs/heads/main "${TICS_CMAIN}"

    # Remote-tracking refs mirroring what the job fetches (supported
    # branches only).
    git -C "${TICS_REPO}" update-ref refs/remotes/origin/3.6 "${TICS_C36}"
    git -C "${TICS_REPO}" update-ref refs/remotes/origin/4.1 "${TICS_C41}"

    # An unrelated root commit that belongs to no supported branch.
    TICS_UNRELATED=$(tics_commit - unrelated)
}

# tics_run <commit> runs the production selection logic in a subshell with
# HEAD detached at that commit (as in the real job) and records the result:
# TICS_RC is the exit code, TICS_OUT the selected project. Script diagnostics
# are echoed to the test log.
tics_run() {
    git -C "${TICS_REPO}" checkout -q --detach "$1"
    # The selection result is captured explicitly inside the subshell, and
    # `|| true` keeps a rejected revision from tripping the harness's `set -e`
    # (in POSIX sh the $( ) assignment's status is the last *executed*
    # command's status, which would otherwise be the failing selection).
    TICS_OUT=$(
        # shellcheck disable=SC2030
        JUJU_REPO="${TICS_REPO}" GIT_COMMIT="$1" TICS_PROJECT=""
        export JUJU_REPO GIT_COMMIT TICS_PROJECT
        # shellcheck disable=SC1091
        . "$(pwd)/jobs/ci-run/scripts/tics-select-project.sh"
        tics_select_project && tics_rc=0 || tics_rc=$?
        echo "TICS_PROJECT=${TICS_PROJECT}"
        echo "TICS_RC=${tics_rc}"
        true
    )
    # sed (not grep -v) so this never returns non-zero under `set -e` when
    # every line is filtered out.
    echo "${TICS_OUT}" | sed "/^TICS_PROJECT=/d;/^TICS_RC=/d"
    TICS_RC=$(echo "${TICS_OUT}" | sed -n 's/^TICS_RC=//p')
    TICS_OUT=$(echo "${TICS_OUT}" | sed -n 's/^TICS_PROJECT=//p')
    return 0
}

tics_expect() {
    # NOTE: no `local` here. This runs under POSIX sh (dash), where `local`
    # inside a function called without a subshell would overwrite the global
    # TICS_RC/TICS_OUT set by tics_run.
    tics_desc="$1"
    tics_want_rc="$2"
    tics_want_project="$3"
    if [ "${TICS_RC}" -ne "${tics_want_rc}" ]; then
        echo "FAIL: ${tics_desc}: expected rc ${tics_want_rc}, got ${TICS_RC}" >&2
        exit 1
    fi
    if [ "${TICS_OUT}" != "${tics_want_project}" ]; then
        echo "FAIL: ${tics_desc}: expected project '${tics_want_project}', got '${TICS_OUT}'" >&2
        exit 1
    fi
    echo "PASS: ${tics_desc}"
}

test_tics_select_project() {
    tics_setup_repo

    tics_run "${TICS_C36}"
    tics_expect "revision unique to 3.6 selects juju_3.6" 0 "juju_3.6"

    tics_run "${TICS_C41}"
    tics_expect "revision unique to 4.1 selects juju" 0 "juju"

    tics_run "${TICS_C40}"
    tics_expect "revision unique to unsupported 4.0 is rejected" 1 ""

    tics_run "${TICS_CMAIN}"
    tics_expect "revision unique to unsupported main is rejected" 1 ""

    tics_run "${TICS_BASE}"
    tics_expect "revision shared by all supported branches picks 4.1 (precedence: newest first)" 0 "juju"

    tics_run "${TICS_UNRELATED}"
    tics_expect "unrelated revision is rejected" 1 ""

    git -C "${TICS_REPO}" update-ref -d refs/remotes/origin/3.6
    tics_run "${TICS_C36}" 2>&1
    tics_expect "missing required ref fails clearly" 2 ""
    TICS_DIAG=$(tics_run "${TICS_C36}" 2>&1)
    if ! echo "${TICS_DIAG}" | grep -q "origin/3.6 is missing"; then
        echo "FAIL: missing ref diagnostic does not name the ref: ${TICS_DIAG}" >&2
        exit 1
    fi
    echo "PASS: missing ref diagnostic names origin/3.6"
}

# Render the analyse-juju-tics job with JJB and extract the shell step that
# embeds the branch-selection helper into tics_rendered_step.sh.
tics_extract_rendered_step() {
    TICS_XML_DIR=$(mktemp -d "${TEST_DIR}/tics-xml.XXX")
    TICS_JJB_CONF=$(mktemp -d "${TEST_DIR}/tics-jjb.XXX")
    cat <<EOF >"${TICS_JJB_CONF}/jenkins-jjb"
[job_builder]
ignore_cache=True
EOF
    # JJB writes a cache lock under XDG_CACHE_HOME; keep it out of the repo
    # (TEST_DIR lives under tests/, which the deadcode check scans).
    TICS_CACHE=$(mktemp -d /tmp/juju-qa-jenkins-jjb-cache.XXXXXX)
    if ! XDG_CACHE_HOME="${TICS_CACHE}" jenkins-jobs --conf "${TICS_JJB_CONF}" test -r "jobs/common:jobs/ci-run" analyse-juju-tics -o "${TICS_XML_DIR}" --config-xml >/dev/null 2>&1; then
        echo "FAIL: could not render analyse-juju-tics with jenkins-jobs" >&2
        exit 1
    fi
    TICS_STEP=$(mktemp "${TEST_DIR}/tics-step.XXX")
    TICS_PREP_STEP=$(mktemp "${TEST_DIR}/tics-prep-step.XXX")
    XML_FILE="${TICS_XML_DIR}/analyse-juju-tics/config.xml" OUT_FILE="${TICS_STEP}" PREP_OUT_FILE="${TICS_PREP_STEP}" python3 - <<'EOF'
import os
import xml.etree.ElementTree as ET

tree = ET.parse(os.environ["XML_FILE"])
cmds = [c.text for c in tree.getroot().iter("command") if c.text and "tics_select_project" in c.text]
if len(cmds) != 1:
    raise SystemExit("expected exactly 1 shell step embedding tics_select_project, got %d" % len(cmds))
with open(os.environ["OUT_FILE"], "w") as f:
    f.write(cmds[0])
prep_cmds = [
    c.text
    for c in tree.getroot().iter("command")
    if c.text and "gocover-cobertura > " in c.text
]
if len(prep_cmds) != 1:
    raise SystemExit("expected exactly 1 coverage-preparation step, got %d" % len(prep_cmds))
if "tics_setup_coverage_mode()" not in prep_cmds[0]:
    raise SystemExit("coverage-preparation step does not embed the coverage-mode helper")
with open(os.environ["PREP_OUT_FILE"], "w") as f:
    f.write(prep_cmds[0])
EOF
    if ! grep -q "tics_select_project()" "${TICS_STEP}"; then
        echo "FAIL: rendered step does not embed the branch-selection helper" >&2
        exit 1
    fi
    # shellcheck disable=SC2016
    if grep -q 'source "\$WORKSPACE/jobs' "${TICS_STEP}"; then
        echo "FAIL: rendered step still sources the absent workspace file" >&2
        exit 1
    fi
    if grep -q "tics-coverage-mode" "${TICS_STEP}" || grep -q "tics-coverage-mode" "${TICS_PREP_STEP}"; then
        echo "FAIL: rendered steps still depend on a workspace copy of tics-coverage-mode.sh" >&2
        exit 1
    fi
    echo "PASS: rendered step embeds helper and drops the workspace source"
}

# Set up a temp agent workspace (no jobs/ci-run/scripts directory), fixture
# juju repo, and stubs for git-fetch/wget/installer/TICSQServer/python3.
tics_setup_rendered_run() {
    tics_setup_repo

    TICS_WS=$(mktemp -d "${TEST_DIR}/tics-ws.XXX")
    if [ -e "${TICS_WS}/jobs" ]; then
        echo "FAIL: test invariant broken: workspace must not contain jobs/" >&2
        exit 1
    fi
    mv "${TICS_REPO}" "${TICS_WS}/juju"
    TICS_REPO="${TICS_WS}/juju"

    TICS_BIN=$(mktemp -d "${TEST_DIR}/tics-bin.XXX")
}

# Writes <content> to the path TICS uses for the unit Cobertura report in the
# fixture workspace; an empty argument removes the
# report instead, and "EMPTY" creates a zero-byte file.
tics_write_coverage_report() {
    if [ "$1" != "unit" ]; then
        echo "FAIL: unknown report kind $1" >&2
        exit 1
    fi
    tics_report_path="${TICS_WS}/juju/.coverage/cobertura.xml"
    rm -rf "$(dirname "${tics_report_path}")"
    if [ -z "$2" ]; then
        return 0
    fi
    mkdir -p "$(dirname "${tics_report_path}")"
    if [ "$2" = "EMPTY" ]; then
        : >"${tics_report_path}"
    else
        printf '%s\n' "$2" >"${tics_report_path}"
    fi
}

# (Re)generate the stub commands for one rendered-step run, embedding the
# current per-run stub log path. TICS_STUB_TICSQSERVER_RC and
# TICS_STUB_PYTHON3_RC select nonzero stub exits for the failure cases.
tics_make_stubs() {
    cat <<EOF >"${TICS_BIN}/git"
#!/bin/bash
# Stub git: intercept network fetches, delegate everything else.
if [ "\$1" = "-C" ] && [ "\$3" = "fetch" ]; then
    echo "git \$(printf '%q ' "\$@")" >> "${TICS_STUB_LOG}"
    exit 0
fi
exec /usr/bin/git "\$@"
EOF
    chmod +x "${TICS_BIN}/git"

    cat <<EOF >"${TICS_BIN}/TICSQServer"
#!/bin/bash
echo "TICSQServer \$(printf '%q ' "\$@")" >> "${TICS_STUB_LOG}"
exit "${TICS_STUB_TICSQSERVER_RC:-0}"
EOF
    chmod +x "${TICS_BIN}/TICSQServer"

    cat <<EOF >"${TICS_BIN}/python3"
#!/bin/bash
echo "python3 \$(printf '%q ' "\$@")" >> "${TICS_STUB_LOG}"
exit "${TICS_STUB_PYTHON3_RC:-0}"
EOF
    chmod +x "${TICS_BIN}/python3"

    # wget doubles as the coverage-download stub: tarballs are written to the
    # -O path so the preparation step can extract them offline.
    cat <<EOF >"${TICS_BIN}/wget"
#!/bin/bash
echo "wget \$(printf '%q ' "\$@")" >> "${TICS_STUB_LOG}"
out=""
prev=""
for arg in "\$@"; do
    if [ "\$prev" = "-O" ]; then
        out="\$arg"
    fi
    prev="\$arg"
done
if [ "\${TICS_STUB_WGET_FAIL:-0}" = "1" ]; then
    exit 1
fi
case "\$out" in
    install-tics.sh)
        cat > "\$out" <<'INSTALLER'
#!/bin/bash
echo "install-tics.sh \$*" >> "${TICS_STUB_LOG}"
INSTALLER
        ;;
    *.tar.gz)
        echo fixture | gzip > "\$out"
        ;;
esac
EOF
    chmod +x "${TICS_BIN}/wget"

    cat <<EOF >"${TICS_BIN}/gocover-cobertura"
#!/bin/bash
echo "gocover-cobertura \$(printf '%q ' "\$@")" >> "${TICS_STUB_LOG}"
cat >/dev/null
if [ "\${TICS_STUB_CONVERT_FAIL:-0}" = "1" ]; then
    echo "not xml"
    exit 1
fi
printf '%s\n' '<coverage version="1"><packages/></coverage>'
EOF
    chmod +x "${TICS_BIN}/gocover-cobertura"

    cat <<EOF >"${TICS_BIN}/go"
#!/bin/bash
echo "go \$(printf '%q ' "\$@")" >> "${TICS_STUB_LOG}"
# Emulate 'go tool covdata textfmt -i=<dir> -o=<file>'.
out=""
for arg in "\$@"; do
    case "\$arg" in
        -o=*) out="\${arg#-o=}" ;;
    esac
done
if [ -n "\$out" ]; then
    : > "\$out"
fi
EOF
    chmod +x "${TICS_BIN}/go"

    cat <<'EOF' >"${TICS_BIN}/mkdir"
#!/bin/bash
# Stub mkdir: tolerate pre-existing dirs so reruns within one case work.
case " $* " in
*" -p "*) exec /bin/mkdir "$@" ;;
*) /bin/mkdir "$@" 2>/dev/null || true ;;
esac
EOF
    chmod +x "${TICS_BIN}/mkdir"
}

# tics_jenkins_interpreter <step-file>: replicates how Jenkins picks the
# interpreter for a shell build step, which is by the shebang on the first
# line of the command. A command whose first line is not a shebang runs
# under the default /bin/sh.
tics_jenkins_interpreter() {
    if [ "$(head -n 1 "$1")" = "#!/bin/bash" ]; then
        echo /bin/bash
    else
        echo /bin/sh
    fi
}

# tics_run_rendered <commit> [step-file]: runs the rendered shell step
# against the temp workspace (default: the analysis step) under the
# interpreter Jenkins would select. TICS_RUN_RC records the exit code. The
# `||` guard keeps an expected non-zero run (unsupported revision) from
# tripping the harness's `set -e` before the status is captured.
tics_run_rendered() {
    git -C "${TICS_REPO}" checkout -q --detach "$1"
    TICS_STUB_LOG=$(mktemp "${TEST_DIR}/tics-stub-log.XXX")
    tics_make_stubs
    TICS_RUN_RC=0
    (
        # Caller-scoped stub behaviour controls; set locally so an env
        # prefix on the call cannot leak into later runs.
        TICS_STUB_WGET_FAIL=${TICS_STUB_WGET_FAIL:-0}
        TICS_STUB_CONVERT_FAIL=${TICS_STUB_CONVERT_FAIL:-0}
        TICS_STUB_TICSQSERVER_RC=${TICS_STUB_TICSQSERVER_RC:-0}
        TICS_STUB_PYTHON3_RC=${TICS_STUB_PYTHON3_RC:-0}
        export TICS_STUB_WGET_FAIL TICS_STUB_CONVERT_FAIL TICS_STUB_TICSQSERVER_RC TICS_STUB_PYTHON3_RC
        export PATH="${TICS_BIN}:${PATH}"
        export WORKSPACE="${TICS_WS}"
        # shellcheck disable=SC2031
        export GIT_COMMIT="$1"
        export GOPATH="${TICS_WS}/.go"
        export HOME="${TICS_WS}/home"
        mkdir -p "${GOPATH}/bin" "${HOME}"
        : >"${HOME}/.profile"
        # Mirrors the injected buildvars contract: unset unless a case
        # exports a value before calling tics_run_rendered.
        if [ -n "${TICS_TEST_COVERAGE_ENABLED+x}" ]; then
            export COVERAGE_ENABLED="${TICS_TEST_COVERAGE_ENABLED}"
        else
            unset COVERAGE_ENABLED
        fi
        # Mirrors the buildvars injected when upstream coverage is enabled;
        # left unset otherwise, as in the disabled build that failed (#47).
        if [ "${TICS_TEST_COVERAGE_ENABLED:-}" = "true" ]; then
            export UNIT_COVERAGE_COLLECT_URL="${UNIT_COVERAGE_COLLECT_URL:-http://stub/unit-coverage.tar.gz}"
        else
            unset UNIT_COVERAGE_COLLECT_URL
        fi
        cd "${TICS_WS}" || exit 1
        "$(tics_jenkins_interpreter "${2:-${TICS_STEP}}")" "${2:-${TICS_STEP}}"
    ) || TICS_RUN_RC=$?
    return 0
}

# tics_run_case <commit> <coverage-enabled-value|UNSET> [--with-prep]: one
# analysis-step run with a controlled COVERAGE_ENABLED environment.
# --with-prep first runs the rendered coverage-preparation step as a
# separate shell process (mirroring separate Jenkins shell steps).
tics_run_case() {
    if [ "$2" = "UNSET" ]; then
        unset TICS_TEST_COVERAGE_ENABLED
    else
        TICS_TEST_COVERAGE_ENABLED="$2"
    fi
    if [ "${3:-}" = "--with-prep" ]; then
        tics_run_rendered "$1" "${TICS_PREP_STEP}"
        TICS_PREP_RC=${TICS_RUN_RC}
    fi
    tics_run_rendered "$1"
    unset TICS_STUB_WGET_FAIL TICS_STUB_CONVERT_FAIL TICS_STUB_TICSQSERVER_RC TICS_STUB_PYTHON3_RC TICS_TEST_COVERAGE_ENABLED
}

test_tics_rendered_step() {
    tics_extract_rendered_step
    tics_setup_rendered_run

    tics_run_case "${TICS_C36}" false
    if [ "${TICS_RUN_RC}" -ne 0 ]; then
        echo "FAIL: rendered step failed for a 3.6 revision (rc ${TICS_RUN_RC})" >&2
        exit 1
    fi
    if ! grep -q "TICSQServer -project juju_3.6" "${TICS_STUB_LOG}"; then
        echo "FAIL: 3.6 revision did not reach stubbed TICSQServer with -project juju_3.6:" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    echo "PASS: rendered step analyses a 3.6 revision with project juju_3.6"

    if ! grep -q "wget .*cfg=GoProjects" "${TICS_STUB_LOG}"; then
        echo "FAIL: rendered step did not download the TICS installer with cfg=GoProjects:" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    if grep -q "cfg=default" "${TICS_STUB_LOG}"; then
        echo "FAIL: rendered step still references the default TICS cfg section:" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    echo "PASS: rendered step downloads the TICS installer with cfg=GoProjects"

    # The stub log is %q-escaped, so commas appear as \,.
    if ! grep -qF -- '-nocalc UNITTESTCOVERAGE\,INTEGRATIONTESTCOVERAGE\,TOTALTESTCOVERAGE' "${TICS_STUB_LOG}"; then
        echo "FAIL: coverage-disabled run did not exclude the configured coverage metrics:" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    if grep -q "python3" "${TICS_STUB_LOG}"; then
        echo "FAIL: coverage-disabled run still validated coverage reports:" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    echo "PASS: coverage-disabled run excludes coverage metrics and skips report validation"

    tics_run_case "${TICS_UNRELATED}" false
    if [ "${TICS_RUN_RC}" -eq 0 ]; then
        echo "FAIL: rendered step succeeded for an unsupported revision" >&2
        exit 1
    fi
    if grep -q "TICSQServer\|install-tics" "${TICS_STUB_LOG}"; then
        echo "FAIL: unsupported revision reached downstream analysis:" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    echo "PASS: unsupported revision stops before downstream analysis"
}

test_tics_coverage_modes() {
    tics_extract_rendered_step
    tics_setup_rendered_run

    TICS_VALID_XML='<coverage version="1"><packages><package name="p"><classes><class name="c" line-rate="0" branch-rate="0"/></classes></package></packages></coverage>'

    # Disabled: the preparation step exits early and the analysis step runs
    # with -nocalc in a separate shell process.
    tics_run_case "${TICS_C36}" false --with-prep
    if [ "${TICS_PREP_RC}" -ne 0 ]; then
        echo "FAIL: coverage-disabled preparation step failed (rc ${TICS_PREP_RC}):" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    if grep -q "gocover-cobertura" "${TICS_STUB_LOG}"; then
        echo "FAIL: coverage-disabled preparation still converted reports:" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    echo "PASS: coverage-disabled preparation step skips download and conversion"

    # Enabled: the preparation step produces the unit report and the analysis
    # step excludes integration and total coverage.
    tics_run_case "${TICS_C36}" true --with-prep
    if [ "${TICS_PREP_RC}" -ne 0 ]; then
        echo "FAIL: coverage-enabled preparation step failed (rc ${TICS_PREP_RC}):" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    if [ ! -s "${TICS_WS}/juju/.coverage/cobertura.xml" ]; then
        echo "FAIL: coverage-enabled preparation did not produce the unit Cobertura report" >&2
        exit 1
    fi
    if [ -e "${TICS_WS}/juju/.integrationcoverage/cobertura.xml" ]; then
        echo "FAIL: unit-only preparation unexpectedly produced an integration report" >&2
        exit 1
    fi
    echo "PASS: coverage-enabled preparation step produces only the unit Cobertura report"
    if [ "${TICS_RUN_RC}" -ne 0 ]; then
        echo "FAIL: coverage-enabled run with valid reports failed (rc ${TICS_RUN_RC}):" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    if ! grep -q "TICSQServer -project juju_3.6" "${TICS_STUB_LOG}"; then
        echo "FAIL: coverage-enabled run did not reach TICSQServer:" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    if ! grep -qF -- '-nocalc INTEGRATIONTESTCOVERAGE\,TOTALTESTCOVERAGE' "${TICS_STUB_LOG}"; then
        echo "FAIL: coverage-enabled run did not exclude integration and total coverage:" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    if grep -qF -- 'UNITTESTCOVERAGE' "${TICS_STUB_LOG}"; then
        echo "FAIL: coverage-enabled run excluded unit coverage:" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    echo "PASS: coverage-enabled run analyses unit coverage only"

    # Enabled with a failing coverage download: the preparation step fails
    # before the analysis step ever runs.
    TICS_TEST_COVERAGE_ENABLED=true
    TICS_STUB_WGET_FAIL=1
    tics_run_rendered "${TICS_C36}" "${TICS_PREP_STEP}"
    unset TICS_STUB_WGET_FAIL TICS_TEST_COVERAGE_ENABLED
    if [ "${TICS_RUN_RC}" -eq 0 ]; then
        echo "FAIL: preparation step succeeded despite a failing coverage download" >&2
        exit 1
    fi
    echo "PASS: failing coverage download fails the preparation step"

    # Enabled with failing conversion: the preparation step fails.
    TICS_TEST_COVERAGE_ENABLED=true
    TICS_STUB_CONVERT_FAIL=1
    tics_run_rendered "${TICS_C36}" "${TICS_PREP_STEP}"
    unset TICS_STUB_CONVERT_FAIL TICS_TEST_COVERAGE_ENABLED
    if [ "${TICS_RUN_RC}" -eq 0 ]; then
        echo "FAIL: preparation step succeeded despite failing conversion" >&2
        exit 1
    fi
    echo "PASS: failing coverage conversion fails the preparation step"

    # An invalid COVERAGE_ENABLED fails in the preparation step as well as
    # the analysis step.
    TICS_TEST_COVERAGE_ENABLED=flase
    tics_run_rendered "${TICS_C36}" "${TICS_PREP_STEP}"
    unset TICS_TEST_COVERAGE_ENABLED
    if [ "${TICS_RUN_RC}" -eq 0 ]; then
        echo "FAIL: preparation step accepted an unexpected COVERAGE_ENABLED value" >&2
        exit 1
    fi
    echo "PASS: unexpected COVERAGE_ENABLED value fails the preparation step"

    # Enabled with a missing report fails before TICS is installed or invoked.
    tics_write_coverage_report unit ""
    tics_run_case "${TICS_C36}" true
    if [ "${TICS_RUN_RC}" -eq 0 ]; then
        echo "FAIL: coverage-enabled run with a missing report succeeded" >&2
        exit 1
    fi
    if grep -q "TICSQServer\|install-tics" "${TICS_STUB_LOG}"; then
        echo "FAIL: missing report was not rejected before analysis:" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    echo "PASS: coverage-enabled run fails before analysis when a report is missing"

    # Enabled with an empty report fails before analysis.
    tics_write_coverage_report unit "EMPTY"
    tics_run_case "${TICS_C36}" true
    if [ "${TICS_RUN_RC}" -eq 0 ]; then
        echo "FAIL: coverage-enabled run with an empty report succeeded" >&2
        exit 1
    fi
    if grep -q "TICSQServer\|install-tics" "${TICS_STUB_LOG}"; then
        echo "FAIL: empty report was not rejected before analysis:" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    echo "PASS: coverage-enabled run fails before analysis when a report is empty"

    # Enabled with a malformed report fails before analysis (python3 nonzero).
    tics_write_coverage_report unit "${TICS_VALID_XML}"
    TICS_STUB_PYTHON3_RC=1
    tics_run_case "${TICS_C36}" true
    unset TICS_STUB_PYTHON3_RC
    if [ "${TICS_RUN_RC}" -eq 0 ]; then
        echo "FAIL: coverage-enabled run with a malformed report succeeded" >&2
        exit 1
    fi
    if grep -q "TICSQServer\|install-tics" "${TICS_STUB_LOG}"; then
        echo "FAIL: malformed report was not rejected before analysis:" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    echo "PASS: coverage-enabled run fails before analysis when a report is malformed"

    # Unset COVERAGE_ENABLED defaults to coverage-disabled.
    tics_run_case "${TICS_C36}" UNSET
    if [ "${TICS_RUN_RC}" -ne 0 ]; then
        echo "FAIL: rendered step failed with unset COVERAGE_ENABLED (rc ${TICS_RUN_RC}):" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    if ! grep -qF -- '-nocalc UNITTESTCOVERAGE\,INTEGRATIONTESTCOVERAGE\,TOTALTESTCOVERAGE' "${TICS_STUB_LOG}"; then
        echo "FAIL: unset COVERAGE_ENABLED did not default to coverage-disabled:" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    echo "PASS: unset COVERAGE_ENABLED defaults to coverage-disabled analysis"

    # An unexpected value fails clearly before analysis.
    tics_run_case "${TICS_C36}" flase
    if [ "${TICS_RUN_RC}" -eq 0 ]; then
        echo "FAIL: rendered step accepted an unexpected COVERAGE_ENABLED value" >&2
        exit 1
    fi
    if grep -q "TICSQServer\|install-tics" "${TICS_STUB_LOG}"; then
        echo "FAIL: unexpected COVERAGE_ENABLED value reached analysis:" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    echo "PASS: unexpected COVERAGE_ENABLED value fails before analysis"

    # A failing TICSQServer fails the step.
    TICS_STUB_TICSQSERVER_RC=7
    tics_run_case "${TICS_C36}" false
    unset TICS_STUB_TICSQSERVER_RC
    if [ "${TICS_RUN_RC}" -ne 7 ]; then
        echo "FAIL: TICSQServer exit 7 was not propagated (rc ${TICS_RUN_RC})" >&2
        exit 1
    fi
    echo "PASS: nonzero TICSQServer exit fails the rendered step"
}

# Regression test for build #47: the coverage-preparation step must render
# with '#!/bin/bash' as its very first line, because Jenkins selects the
# interpreter by the leading shebang. A helper comment first would make
# Jenkins run the step under /bin/sh, where Bash conditionals fail.
test_tics_coverage_prep_interpreter() {
    tics_extract_rendered_step
    tics_setup_rendered_run

    if [ "$(head -n 1 "${TICS_PREP_STEP}")" != "#!/bin/bash" ]; then
        echo "FAIL: coverage-preparation step does not start with #!/bin/bash:" >&2
        head -3 "${TICS_PREP_STEP}" >&2
        exit 1
    fi
    if ! grep -q "tics_setup_coverage_mode()" "${TICS_PREP_STEP}"; then
        echo "FAIL: coverage-preparation step does not embed the helper" >&2
        exit 1
    fi
    echo "PASS: coverage-preparation step starts with the Bash shebang and embeds the helper"

    # Coverage disabled with the URLs unset must skip preparation cleanly,
    # under whichever interpreter Jenkins selects. Stub wget/gocover-cobertura
    # would record any unexpected download or conversion in the stub log.
    unset UNIT_COVERAGE_COLLECT_URL
    tics_run_case "${TICS_C36}" false --with-prep
    if [ "${TICS_PREP_RC}" -ne 0 ]; then
        echo "FAIL: coverage-disabled preparation step failed (rc ${TICS_PREP_RC})" >&2
        exit 1
    fi
    if grep -q "gocover-cobertura\|wget .*coverage" "${TICS_STUB_LOG}"; then
        echo "FAIL: coverage-disabled preparation downloaded or converted reports:" >&2
        cat "${TICS_STUB_LOG}" >&2
        exit 1
    fi
    echo "PASS: coverage-disabled preparation skips download and conversion with URLs unset"
}

test_tics() {
    if [ "$(skip 'test_tics')" ]; then
        echo "==> TEST SKIPPED: tics selection tests"
        return
    fi

    (
        set_verbosity

        cd .. || exit

        run "test_tics_select_project"
        run "test_tics_rendered_step"
        run "test_tics_coverage_modes"
        run "test_tics_coverage_prep_interpreter"
    )
}
