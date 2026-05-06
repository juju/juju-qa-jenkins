STATIC_ANALYSIS_JOB    ?=
IGNORE_STATIC_ANALYSIS ?=
PUSH_JOB               ?=
PUSH_TARGET            ?= "jobs/ci-run"
JJB_CONF_PATH          ?= jenkins-jjb

cwd              = $(shell pwd)
virtualenv_dir   = $(cwd)/venv

UV := $(shell command -v uv 2>/dev/null)

.PHONY: ensure-venv
ensure-venv:
ifdef UV
	uv venv --python 3.11 $(virtualenv_dir) --allow-existing --seed
else
	python3 -m venv $(virtualenv_dir)
endif

.PHONY: install-deps
install-deps: ensure-venv
ifdef UV
	VIRTUAL_ENV=$(virtualenv_dir) UV_CONSTRAINT=./constraint.txt uv pip install -r requirements.txt
else
	$(virtualenv_dir)/bin/pip install -c ./constraint.txt -r requirements.txt
endif
	# The postbuildscript plugin version is "3.1.0-375.v3db_cd92485e1" which cannot be parsed.
	# So we override to set it to "3.1.0".
	# jenkins-job-builder only cares if the plugin version is > 2.
	# For jenkins-job-builder 3.12.0, look for:
	#   info = registry.get_plugin_info("postbuildscript")
	#   # Note: Assume latest version of plugin is preferred config format
	#   version = pkg_resources.parse_version(info.get("version", str(sys.maxsize)))
	# Replace the last line to override the version.
	find -wholename '*jenkins_jobs/modules/publishers.py' -print0 | xargs -0 sed -i '/info = registry.get_plugin_info("postbuildscript")/!b;n;n;c\    version = pkg_resources.parse_version("3.1.0")'

ifdef IGNORE_STATIC_ANALYSIS
push:
else
push: static-analysis
endif
	. $(virtualenv_dir)/bin/activate; jenkins-jobs --conf "${JJB_CONF_PATH}" \
		--user "${JENKINS_USER}" \
		--password "${JENKINS_ACCESS_TOKEN}" \
		update --workers $(shell nproc) -r "jobs/common:${PUSH_TARGET}" ${PUSH_JOB}

test-push: static-analysis
	. $(virtualenv_dir)/bin/activate; jenkins-jobs --conf "${JJB_CONF_PATH}" \
		--user "${JENKINS_USER}" \
		--password "${JENKINS_ACCESS_TOKEN}" \
		test "jobs/common:${PUSH_TARGET}" ${PUSH_JOB}

push-local: static-analysis
	. $(virtualenv_dir)/bin/activate; jenkins-jobs --conf "${LOCAL_JJB_CONF}" \
		update -r "jobs/common:${PUSH_TARGET}" ${PUSH_JOB}

build-xml: static-analysis
	. $(virtualenv_dir)/bin/activate; jenkins-jobs \
		test "jobs/common:jobs/ci-run:jobs/github" -o "${cwd}/_build" --config-xml

static-analysis: install-deps
	. $(virtualenv_dir)/bin/activate; cd tests && ./main.sh static_analysis "${STATIC_ANALYSIS_JOB}"

tests: install-deps
	. $(virtualenv_dir)/bin/activate; cd tests && ./main.sh

dot-graph:
	$(eval tmpfile := $(shell mktemp))
	@echo "" >"$(tmpfile)"; go run ./tools/dag/main.go "${PWD}/jobs"<"$(tmpfile)"

collect-wire-tests:
	@if [ -z "$$GH_TOKEN" ] && command -v gh >/dev/null 2>&1; then \
		export GH_TOKEN=$$(gh auth token 2>/dev/null); \
	fi; \
	if [ -z "$$GH_TOKEN" ]; then \
		echo "GH_TOKEN must be set or gh CLI must be authenticated"; \
		exit 1; \
	fi; \
	go run ./tools/gen-wire-tests/main.go collect \
		"./tools/gen-wire-tests"

gen-wire-tests:
	$(eval config := "./tools/gen-wire-tests/juju.config")
	@go run ./tools/gen-wire-tests/main.go generate \
		"./tools/gen-wire-tests" \
		"./jobs/ci-run/integration/gen" \
		<"${config}"

.PHONY: collect-wire-tests gen-wire-tests clean
clean:
	rm -rf venv
	find $(cwd) -iname "*.pyc" -delete

.PHONY: tests
