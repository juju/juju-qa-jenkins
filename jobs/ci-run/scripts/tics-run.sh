tics_select_project

tics_setup_coverage_mode
if [ -z "${TICS_PROJECT:-}" ]; then
    echo "ERROR: TICS_PROJECT is not set; branch selection did not produce a project" >&2
    exit 1
fi
if [ "${TICS_COVERAGE_ENABLED}" = "true" ]; then
    echo "upstream COVERAGE_ENABLED=true: validating unit coverage report before analysis..."
    tics_validate_coverage_reports
else
    echo "upstream COVERAGE_ENABLED=${COVERAGE_ENABLED:-false}: excluding TICS coverage calculations (${TICS_COVERAGE_METRICS})"
fi

echo "installing TICS..."
wget -O install-tics.sh 'https://canonical.tiobe.com/tiobeweb/TICS/api/public/v1/fapi/installtics/Script?cfg=GoProjects&platform=linux&url=https://canonical.tiobe.com/tiobeweb/TICS/'
chmod +x install-tics.sh
./install-tics.sh

echo "setup completed! running the TICSQServer... this can take a while..."
mkdir -p /tmp/tics
source $HOME/.profile

tics_args=(
    -project "${TICS_PROJECT:-}"
    -tmpdir /tmp/tics
    -branchdir "$WORKSPACE/juju"
    -nosanity
    -language GO
)
if [ -n "$TICS_NOCALC_ARG" ]; then
    # Word-splitting intended: -nocalc takes the comma-separated metric list.
    # shellcheck disable=SC2086
    tics_args+=($TICS_NOCALC_ARG)
fi
TICSQServer "${tics_args[@]}"
