# Coverage mode for the TICS analysis, driven by the upstream buildvars
# setting. This file is sourced, not executed, and must stay POSIX-sh
# compatible. It expects nothing and reads:
#   COVERAGE_ENABLED: "true" enables coverage, unset/empty defaults to
#   disabled, any other value is a configuration error.
# It sets:
#   TICS_COVERAGE_ENABLED: "true" or "false", for later gating.
#   TICS_NOCALC_ARG:       the -nocalc argument excluding coverage metrics
#   that have no report. Integration and total coverage are always excluded;
#   unit coverage is also excluded when collection is disabled.

TICS_COVERAGE_METRICS="UNITTESTCOVERAGE,INTEGRATIONTESTCOVERAGE,TOTALTESTCOVERAGE"
TICS_NON_UNIT_COVERAGE_METRICS="INTEGRATIONTESTCOVERAGE,TOTALTESTCOVERAGE"

tics_setup_coverage_mode() {
    TICS_NOCALC_ARG=""
    case "${COVERAGE_ENABLED:-false}" in
        true)
            TICS_COVERAGE_ENABLED=true
            TICS_NOCALC_ARG="-nocalc ${TICS_NON_UNIT_COVERAGE_METRICS}"
            ;;
        false)
            TICS_COVERAGE_ENABLED=false
            TICS_NOCALC_ARG="-nocalc ${TICS_COVERAGE_METRICS}"
            ;;
        *)
            echo "ERROR: unexpected COVERAGE_ENABLED value '${COVERAGE_ENABLED}'; expected 'true', 'false' or unset" >&2
            return 2
            ;;
    esac
}

# Verifies the unit Cobertura report produced by the coverage-preparation
# step. It must exist, be non-empty and parse as XML with a <coverage> root.
tics_validate_coverage_reports() {
    local report
    report="$WORKSPACE/juju/.coverage/cobertura.xml"
    if [ ! -s "$report" ]; then
        echo "ERROR: COVERAGE_ENABLED=true but coverage report $report is missing or empty" >&2
        return 1
    fi
    if ! REPORT="$report" python3 -c 'import os, xml.etree.ElementTree as ET; root = ET.parse(os.environ["REPORT"]).getroot(); assert root.tag == "coverage", "root element is <%s>, expected <coverage>" % root.tag'; then
        echo "ERROR: COVERAGE_ENABLED=true but coverage report $report is not a well-formed Cobertura XML report" >&2
        return 1
    fi
}
