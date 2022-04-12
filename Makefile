STATIC_ANALYSIS_JOB ?=
PUSH_JOB			?=
PUSH_TARGET			?= "jobs/ci-run"
JJB_CONF_PATH		?= ~/cloud-city/jenkins-jjb
JUJU_REPO_PATH		?= "${GOPATH}/src/github.com/juju/juju"

cwd 			 = $(shell pwd)
virtualenv_dir 	 = $(cwd)/venv
python_base_path = $(shell which python3)

.PHONY: ensure-venv
ensure-venv:
	pip3 install virtualenv
	test -d venv || virtualenv -p $(python_base_path) $(virtualenv_dir)

.PHONY: install-deps
install-deps: ensure-venv
	$(virtualenv_dir)/bin/pip3 install -r requirements.txt
	# The postbuildscript plugin version is "3.1.0-375.v3db_cd92485e1" which cannot be parsed.
	# So we override to set it to "3.1.0".
	# jenkins-job-builder only cares if the plugin version is > 2.
	# For jenkins-job-builder 3.12.0, look for:
	#   info = registry.get_plugin_info("postbuildscript")
	#   # Note: Assume latest version of plugin is preferred config format
	#   version = pkg_resources.parse_version(info.get("version", str(sys.maxsize)))
	# Replace the last line to override the version.
	find -wholename '*jenkins_jobs/modules/publishers.py' -print0 | xargs -0 sed -i '/info = registry.get_plugin_info("postbuildscript")/!b;n;n;c\    version = pkg_resources.parse_version("3.1.0")'

push: static-analysis
	. $(virtualenv_dir)/bin/activate; jenkins-jobs --conf ${JJB_CONF_PATH} \
		--user ${JENKINS_USER} \
		--password ${JENKINS_ACCESS_TOKEN} \
		update -r "jobs/common:${PUSH_TARGET}" ${PUSH_JOB}

test-push: static-analysis
	. $(virtualenv_dir)/bin/activate; jenkins-jobs --conf ${JJB_CONF_PATH} \
		--user ${JENKINS_USER} \
		--password ${JENKINS_ACCESS_TOKEN} \
		test "jobs/common:${PUSH_TARGET}" ${PUSH_JOB}

push-local: static-analysis
	. $(virtualenv_dir)/bin/activate; jenkins-jobs --conf ${LOCAL_JJB_CONF} \
		update -r "jobs/common:${PUSH_TARGET}" ${PUSH_JOB}

static-analysis: install-deps
	. $(virtualenv_dir)/bin/activate; cd tests && ./main.sh static_analysis ${STATIC_ANALYSIS_JOB}

tests: install-deps
	. $(virtualenv_dir)/bin/activate; cd tests && ./main.sh

dot-graph:
	$(eval tmpfile := $(shell mktemp))
	@echo "" >"$(tmpfile)"; go run ./tools/dag/main.go "${PWD}/jobs"<"$(tmpfile)"

gen-wire-tests:
	$(eval config := "./tools/gen-wire-tests/juju.config")
	@go run ./tools/gen-wire-tests/main.go\
		"${JUJU_REPO_PATH}/tests/suites"\
		"./jobs/ci-run/integration/gen"\
		<"${config}"

IMAGES_AMI_PACKER := $(wildcard images/ami/*.json)
AWS_ACCESS_KEY_ID ?=
AWS_SECRET_ACCESS_KEY ?=

images-ami: $(IMAGES_AMI_PACKER)
	@go run ./tools/ami-cleanup/main.go

$(IMAGES_AMI_PACKER):
	@packer build $@

.PHONY: clean
clean:
	rm -rf venv
	find $(cwd) -iname "*.pyc" -delete

.PHONY: tests
.PHONY: images-ami $(IMAGES_AMI_PACKER)
