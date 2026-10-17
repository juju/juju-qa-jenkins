PATH=$GOPATH/bin:$PATH

tics_setup_coverage_mode
if [[ "${TICS_COVERAGE_ENABLED}" != "true" ]]; then
  echo "upstream COVERAGE_ENABLED=${COVERAGE_ENABLED:-false}: skipping coverage report download and conversion"
  exit 0
fi

echo "downloading unit coverage..."
work="$WORKSPACE/.tics-coverage-work"
rm -rf "$work"
mkdir -p "$work"
wget -O "$work/unit-coverage.tar.gz" "$UNIT_COVERAGE_COLLECT_URL"
unit_coverage_dir=$work/unit
mkdir "$unit_coverage_dir"
tar -xvf "$work/unit-coverage.tar.gz" -C "$unit_coverage_dir"

echo "converting coverage data to go txtfmt..."
go tool covdata textfmt -i="$unit_coverage_dir" -o="$work/unit.txt"

echo "converting coverage data to cobertura..."
mkdir "$WORKSPACE/juju/.coverage"
(cd "$WORKSPACE/juju" && cat "$work/unit.txt" | gocover-cobertura > "$WORKSPACE/juju/.coverage/cobertura.xml")
