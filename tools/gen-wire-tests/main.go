package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"text/template"

	"github.com/schollz/progressbar/v3"
	"gopkg.in/yaml.v2"
	"mvdan.cc/sh/v3/syntax"
)

// Config represents the different ways to config the linter
type Config struct {
	Folders struct {
		Skip         []string                  `yaml:"skip-all"`
		SkipLXD      []string                  `yaml:"skip-lxd"`
		SkipAWS      []string                  `yaml:"skip-aws"`
		SkipGoogle   []string                  `yaml:"skip-google"`
		SkipAzure    []string                  `yaml:"skip-azure"`
		SkipMicrok8s []string                  `yaml:"skip-microk8s"`
		SkipSubTasks []string                  `yaml:"skip-subtasks"`
		PreventSplit []string                  `yaml:"prevent-split"`
		Ephemeral    []string                  `yaml:"ephemeral"`
		CrossCloud   []string                  `yaml:"cross-cloud"`
		Timeout      map[string]map[string]int `yaml:"timeout"`
		Introduced   map[string]string         `yaml:"introduced"`
		Removed      map[string]string         `yaml:"removed"`
	}
}

type Task struct {
	Clouds        []Cloud
	SubTasks      []string
	ExcludedTasks []string
	Timeout       map[string]int
}

type Cloud struct {
	Name         string
	CloudName    string
	ProviderName string
	Region       string
}

var (
	lxd      = Cloud{Name: "lxd", CloudName: "localhost", ProviderName: "lxd"}
	aws      = Cloud{Name: "aws", CloudName: "aws", ProviderName: "ec2", Region: "us-east-1"}
	google   = Cloud{Name: "google", CloudName: "google", ProviderName: "gce", Region: "us-east1"}
	azure    = Cloud{Name: "azure", CloudName: "azure", ProviderName: "azure", Region: "eastus"}
	microk8s = Cloud{Name: "microk8s", CloudName: "microk8s", ProviderName: "k8s"}
)

// minVersionRegex is a map from relevant minor semantic version releases
// to regexps that match versions matching or later. Regexps need to match
// the entire version string
//
// Do this for 3.n versions by:
//   - Matching any major version 4 or later; or
//   - for versions 3.n, match if the minor version has 2+ digits or is a
//     single digit greater than or equal to n
var minVersionRegex = map[string]string{
	"3.0": "^[4-9].*|^3\\\\.([0-9]|\\\\d{{2,}})(\\\\.|-).*",
	"3.1": "^[4-9].*|^3\\\\.([1-9]|\\\\d{{2,}})(\\\\.|-).*",
	"3.2": "^[4-9].*|^3\\\\.([2-9]|\\\\d{{2,}})(\\\\.|-).*",
	"3.3": "^[4-9].*|^3\\\\.([3-9]|\\\\d{{2,}})(\\\\.|-).*",
	"3.4": "^[4-9].*|^3\\\\.([4-9]|\\\\d{{2,}})(\\\\.|-).*",
	"3.5": "^[4-9].*|^3\\\\.([5-9]|\\\\d{{2,}})(\\\\.|-).*",
	"3.6": "^[4-9].*|^3\\\\.([6-9]|\\\\d{{2,}})(\\\\.|-).*",
	"4.0": "^[5-9].*|^4\\\\.([0-9]|\\\\d{{2,}})(\\\\.|-).*",
}

// Override tests if testing on personal branches.
const (
	v4BranchName = "main"
	v3BranchName = "3.6"
	repoOrg      = "juju"
)

// Gen-wire-tests will generate the integration test files for the juju
// integration tests. This will help prevent wire up mistakes or any missing
// test suite tests.
//
// It expects two arguments to be passed in:
// - outputDir: the location of the new jenkins config files
//
// Additionally it expects a config file passed in via stdin, this allows the
// configuration of the gen-wire-tests. In reality it allows the skipping of
// folders that are custom and don't follow the generic setup.
func main() {
	if len(os.Args) < 1 {
		log.Fatal("expected directory argument only.")
	}
	outputDir := os.Args[1]

	if outDir, err := os.Open(outputDir); os.IsNotExist(err) {
		if err := os.MkdirAll(outputDir, os.ModePerm); err != nil {
			log.Fatal("unable to create output dir", outputDir)
		}
	} else {
		log.Printf("Warning: Output directory %q already exists. It may overwrite files!\n", outputDir)
		// Remove all yaml files so that git can track deleted files as well as new ones.
		outFiles, err := outDir.Readdirnames(0)
		if err != nil {
			log.Println("")
			log.Fatalf("unable to read output dir files: %v\n "+
				"If you are having an issue reading from stdin, check your terminal is not part of a strictly confined snap (e.g. an built-in IDE terminal)", err)
		}
		for _, f := range outFiles {
			if !strings.HasSuffix(f, ".yml") {
				continue
			}
			if err := os.Remove(filepath.Join(outputDir, f)); err != nil {
				log.Fatalf("unable to remove existing file %q: %v", f, err)
			}
		}
	}

	reader := bufio.NewReader(os.Stdin)
	bytes, err := io.ReadAll(reader)
	if err != nil {
		log.Fatal("unexpected config: ", err)
	}
	var config Config
	if err := yaml.Unmarshal(bytes, &config); err != nil {
		log.Fatal("config parse error: ", err)
	}

	v4fourSuiteInfo := fetchSuitesFromRepo(v4BranchName)

	// Create progress bar ASAP with known info.
	pb := progressbar.NewOptions(2*len(v4fourSuiteInfo),
		progressbar.OptionUseANSICodes(false),
		progressbar.OptionSetTheme(progressbar.ThemeASCII),
		progressbar.OptionShowElapsedTimeOnFinish(),
		progressbar.OptionSetWidth(50),
		progressbar.OptionSetDescription("Reading test suites..."),
		progressbar.OptionSetTheme(progressbar.Theme{
			Saucer:        "=",
			SaucerHead:    ">",
			SaucerPadding: " ",
			BarStart:      "[",
			BarEnd:        "]",
		}))

	v3SuiteInfo := fetchSuitesFromRepo(v3BranchName)

	v4Tests := fetchTestsFromRepo(pb, config, v4fourSuiteInfo)
	v3Tests := fetchTestsFromRepo(pb, config, v3SuiteInfo)

	// Finish the progress bar.
	_ = pb.Exit()
	fmt.Println()

	funcMap := map[string]interface{}{
		"ensureHyphen": func(s string) string {
			return strings.ReplaceAll(s, "_", "-")
		},
		"contains": func(arr []string, s string) bool {
			for _, v := range arr {
				if s == v {
					return true
				}
			}
			return false
		},
	}
	t := template.Must(template.New("integration").Funcs(funcMap).Parse(Template))

	allTests := make(map[string]Task)
	for suiteName, task := range v3Tests {
		allTests[suiteName] = task
		if _, ok := v4Tests[suiteName]; !ok {
			config.Folders.Removed[suiteName] = "4.0"
		}
	}
	for suiteName, task := range v4Tests {
		allTests[suiteName] = task
	}

	for suiteName, task := range allTests {
		writeJobDefinitions(t, config, outputDir, task, suiteName)
	}
}

type ghObject struct {
	Name        string `json:"name"`
	Path        string `json:"path"`
	Type        string `json:"type"`
	URL         string `json:"url"`
	DownloadURL string `json:"download_url"`
}

func fetchGithubObjects(url string) ([]ghObject, error) {
	client := http.DefaultClient
	req, _ := http.NewRequest("GET", url, nil)

	req.Header.Add("Accept", "application/vnd.github+json")
	token := os.Getenv("GH_TOKEN")
	if token != "" {
		req.Header.Add("Authorization", fmt.Sprintf("Bearer %s", token))
	}
	resp, err := client.Do(req)
	if err != nil {
		log.Fatalf("unable to fetch URL %q: %v", url, err)
	}
	if resp.StatusCode != 200 {
		log.Fatalf("unable to fetch URL %q; status code %d", url, resp.StatusCode)
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Fatalf("unable to get URL %q content: %v", url, err)
	}
	var ghObjects []ghObject
	err = json.Unmarshal(data, &ghObjects)
	if err != nil {
		log.Fatalf("unable to unmarshal URL %q content: %v", url, err)
	}
	return ghObjects, nil
}

func fetchSuitesFromRepo(branch string) []ghObject {
	url := fmt.Sprintf("https://api.github.com/repos/%s/juju/contents/tests/suites?ref=%s", repoOrg, branch)
	ghObjects, err := fetchGithubObjects(url)
	if err != nil {
		log.Fatal("unable to fetch GitHub objects: ", err)
	}

	var ghDirectories []ghObject
	for _, o := range ghObjects {
		if o.Type != "dir" {
			continue
		}
		ghDirectories = append(ghDirectories, o)
	}
	return ghDirectories
}

func fetchTestsFromRepo(pb *progressbar.ProgressBar, config Config, suiteInfo []ghObject) map[string]Task {
	var suiteNames []string
	testSuites := make(map[string]Task)
	for _, dir := range suiteInfo {
		suiteName := dir.Name
		pb.Add(1)

		if contains(config.Folders.Skip, suiteName) {
			continue
		}
		// Expose all non skipped sub-tasks!
		taskNames := []string{suiteName}
		excluded := []string{}
		if !contains(config.Folders.PreventSplit, suiteName) {
			taskNames = []string{}
			subTaskNames := parseTaskNames(dir)
			for _, subTask := range subTaskNames {
				if !contains(config.Folders.SkipSubTasks, subTask) {
					taskNames = append(taskNames, subTask)
				} else {
					excluded = append(excluded, subTask)
				}
			}
		}

		suiteNames = append(suiteNames, suiteName)

		clouds := make([]Cloud, 0)
		if !contains(config.Folders.SkipAWS, suiteName) {
			clouds = append(clouds, aws)
		}
		if !contains(config.Folders.SkipAzure, suiteName) {
			clouds = append(clouds, azure)
		}
		if !contains(config.Folders.SkipGoogle, suiteName) {
			clouds = append(clouds, google)
		}
		if !contains(config.Folders.SkipLXD, suiteName) {
			clouds = append(clouds, lxd)
		}
		if !contains(config.Folders.SkipMicrok8s, suiteName) {
			clouds = append(clouds, microk8s)
		}

		testSuites[suiteName] = Task{
			Clouds:        clouds,
			SubTasks:      taskNames,
			ExcludedTasks: excluded,
			Timeout:       config.Folders.Timeout[suiteName],
		}
	}
	return testSuites
}

func writeJobDefinitions(
	t *template.Template,
	config Config,
	outputDir string,
	task Task,
	suiteName string,
) {
	outputPath := filepath.Join(outputDir, fmt.Sprintf("test-%s.yml", suiteName))
	f, err := os.Create(outputPath)
	if err != nil {
		log.Fatal("unable to create output file", outputPath)
	}
	defer f.Close()

	skipTasks := make([][]string, len(task.SubTasks))
	for k := range task.SubTasks {
		for x, y := range task.SubTasks {
			if k == x {
				continue
			}
			skipTasks[k] = append(skipTasks[k], y)
		}
		sort.Slice(skipTasks[k], func(i, j int) bool {
			return skipTasks[k][i] < skipTasks[k][j]
		})
	}
	joined := make([]string, len(skipTasks))
	for k, v := range skipTasks {
		v = append(v, task.ExcludedTasks...)
		joined[k] = strings.Join(v, ",")
	}

	ephemeral := make(map[string]bool)
	for _, test := range config.Folders.Ephemeral {
		ephemeral[test] = true
	}

	crossCloud := make(map[string]bool)
	for _, test := range config.Folders.CrossCloud {
		crossCloud[test] = true
	}

	minVersions := make(map[string]string)
	maxVersions := make(map[string]string)
	for _, task := range task.SubTasks {
		if introduced, ok := config.Folders.Introduced[task]; ok {
			minVersions[task] = minVersionRegex[introduced]
		}
		if introduced, ok := config.Folders.Introduced[suiteName+"-"+task]; ok {
			minVersions[suiteName+"-"+task] = minVersionRegex[introduced]
		}
		if introduced, ok := config.Folders.Introduced[suiteName]; ok {
			minVersions[suiteName+"-"+task] = minVersionRegex[introduced]
		}
		if removed, ok := config.Folders.Removed[suiteName+"-"+task]; ok {
			maxVersions[suiteName+"-"+task] = minVersionRegex[removed]
		}
		if removed, ok := config.Folders.Removed[suiteName]; ok {
			maxVersions[suiteName+"-"+task] = minVersionRegex[removed]
		}
	}

	if err := t.Execute(f, struct {
		SuiteName     string
		Clouds        []Cloud
		TaskNames     []string
		SkipTasks     []string
		ExcludedTasks string
		Ephemeral     map[string]bool
		CrossCloud    map[string]bool
		Timeout       map[string]int
		MinVersions   map[string]string
		MaxVersions   map[string]string
	}{
		SuiteName:     suiteName,
		Clouds:        task.Clouds,
		TaskNames:     task.SubTasks,
		SkipTasks:     joined,
		ExcludedTasks: strings.Join(task.ExcludedTasks, ","),
		Ephemeral:     ephemeral,
		CrossCloud:    crossCloud,
		Timeout:       task.Timeout,
		MinVersions:   minVersions,
		MaxVersions:   maxVersions,
	}); err != nil {
		log.Fatalf("unable to execute template %q with error %v", suiteName, err)
	}
	f.Sync()
}

func parseTaskNames(dir ghObject) []string {
	tasks := make(map[string]int)

	ghObjects, err := fetchGithubObjects(dir.URL)
	if err != nil {
		log.Fatalf("unable to fetch test suite %q files: %v", dir.Name, err)
	}

	for _, f := range ghObjects {
		if !strings.HasSuffix(f.Name, ".sh") {
			continue
		}

		req, _ := http.NewRequest("GET", f.DownloadURL, nil)
		token := os.Getenv("GH_TOKEN")
		if token == "" {
			req.Header.Add("Authorization", fmt.Sprintf("Bearer %s", token))
		}

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			log.Fatalf("unable to get test file %q context: %v", f.Name, err)
		}
		if resp.StatusCode != 200 {
			_ = resp.Body.Close()
			log.Fatalf("unable to get test file %q context; status code: %d", f.Name, resp.StatusCode)
		}

		parser := syntax.NewParser(syntax.Variant(syntax.LangBash))
		prog, err := parser.Parse(resp.Body, "task.sh")
		if err != nil {
			_ = resp.Body.Close()
			log.Fatalf("unable to parse test suite task content with error %v", err)
		}
		_ = resp.Body.Close()
		syntax.Walk(prog, func(node syntax.Node) bool {
			switch t := node.(type) {
			case *syntax.FuncDecl:
				// Capture the name of the function.
				if !strings.HasPrefix(t.Name.Value, "test_") {
					return true
				}

				// Traverse the function body to ensure that anything with
				// test is called.
				if _, ok := tasks[t.Name.Value]; !ok {
					tasks[t.Name.Value] = 1
				} else {
					tasks[t.Name.Value]++
				}

				syntax.Walk(t.Body, func(node syntax.Node) bool {
					switch t := node.(type) {
					case *syntax.CallExpr:
						// We're not interested in items called outside of our
						// function case.
						if len(t.Args) == 0 {
							return true
						}
						for _, arg := range t.Args {
							lit, ok := arg.Parts[0].(*syntax.Lit)
							if !ok || !strings.HasPrefix(lit.Value, "test_") {
								return true
							}
							if _, ok := tasks[lit.Value]; !ok {
								tasks[lit.Value] = 1
							} else {
								tasks[lit.Value]++
							}
						}

						return true
					}
					return true
				})

			}
			return true
		})
	}

	subtasks := make([]string, 0, len(tasks))
	for name, count := range tasks {
		if count < 2 {
			continue
		}
		subtasks = append(subtasks, name)
	}
	sort.Strings(subtasks)
	return subtasks
}

func contains(haystack []string, needle string) bool {
	for _, skip := range haystack {
		if needle == skip {
			return true
		}
	}
	return false
}

// Template represents the integration test configuration for jenkins job
// builder to run.
const Template = `
{{$node := .}}
# Code generated by gen-wire-tests. DO NOT EDIT.
- job:
    name: 'test-{{$.SuiteName}}-multijob'
    project-type: 'multijob'
    description: |-
        Test {{.SuiteName}} Suite
    condition: SUCCESSFUL
    node: noop-parent-jobs
    concurrent: true
    wrappers:
    - ansicolor
    - workspace-cleanup
    - timestamps
    parameters:
    - string:
        default: ''
        description: 'Enable sub job to be run individually.'
        name: SHORT_GIT_COMMIT
    - string:
        default: ''
        description: 'Build arch used to download the build tar.gz.'
        name: BUILD_ARCH
    builders:
    - get-s3-build-details
    - set-test-description
{{- if gt (len $node.TaskNames) 0 }}
    - multijob:
        name: 'IntegrationTests-{{.SuiteName}}'
        projects:
{{- range $k, $skip_tasks := $node.SkipTasks}}
{{- range $cloud := $node.Clouds}}
    {{- $task_name := index $node.TaskNames $k}}
        - name: 'test-{{$.SuiteName}}-{{ensureHyphen $task_name}}-{{$cloud.Name}}'
          current-parameters: true
{{- end}}
{{- end}}
{{- end}}

{{- range $k, $skip_tasks := $node.SkipTasks -}}
{{- range $cloud := $node.Clouds -}}
    {{- $task_name := "" -}}
    {{- $test_name := (printf "%s-%s" $.SuiteName $cloud.Name) -}}
    {{- $task_name = index $node.TaskNames $k -}}
    {{- $full_task_name := (printf "test-%s-%s-%s" $.SuiteName (ensureHyphen $task_name) $cloud.Name) -}}

    {{- $builder := "run-integration-test" -}}
    {{- $run_on := "ephemeral-noble-small-amd64" -}}
    {{- if or (eq (index $node.Ephemeral $test_name) true) (eq $cloud.ProviderName "lxd") }}
      {{- $builder = "run-integration-test" -}}
      {{- $run_on = "ephemeral-noble-8c-32g-amd64" -}}
    {{- end }}
    {{- if or (eq (index $node.CrossCloud $test_name) true) (eq $cloud.Name "microk8s") }}
      {{- $builder = "run-integration-test-microk8s" -}}
      {{- $run_on = "ephemeral-noble-8c-32g-amd64" -}}
    {{- end }}
{{$timeout := (index $node.Timeout $task_name)}}
- job:
    name: {{$full_task_name}}
    node: {{$run_on}}
    concurrent: true
    description: |-
    {{- if eq (len $node.SkipTasks) 1 }}
      Test {{$.SuiteName}} suite on {{$cloud.Name}}
    {{ else }}
      Test {{$task_name}} in {{$.SuiteName}} suite on {{$cloud.Name}}
    {{ end -}}
    parameters:
    - validating-string:
        name: SHORT_GIT_COMMIT
        description: 'Enable sub job to be run individually.'
        regex: ^\S{{"{{7}}"}}$
        msg: Enter a valid 7 char git sha
    - choice:
        default: 'amd64'
        description: 'Build arch used to download the build tar.gz.'
        name: BUILD_ARCH
        choices:
        - amd64
        - arm64
        - s390x
        - ppc64el
    - choice:
        default: ''
        description: 'Arch used to boostrap controller.'
        name: BOOTSTRAP_ARCH
        choices:
        - amd64
        - arm64
        - s390x
        - ppc64el
    - choice:
        default: ''
        description: 'Arch used for hosted models.'
        name: MODEL_ARCH
        choices:
        - amd64
        - arm64
        - s390x
        - ppc64el
    - string:
        default: '{{$cloud.CloudName}}'
        description: 'Cloud to use when bootstrapping Juju'
        name: BOOTSTRAP_CLOUD
    - string:
        default: '{{$cloud.ProviderName}}'
        description: 'Provider to use when bootstrapping Juju'
        name: BOOTSTRAP_PROVIDER
{{- if $cloud.Region }}
    - string:
        default: '{{$cloud.Region}}'
        description: 'Cloud Region to use when bootstrapping Juju'
        name: BOOTSTRAP_REGION
{{- end }}
    wrappers:
      - default-integration-test-wrapper
      - timeout:
          timeout: {{- if gt $timeout 0 }} {{$timeout}}{{ else }} 30{{- end}}
          fail: true
          type: absolute
    builders:
      - common
      - select-oci-registry
      - prepare-integration-test
{{- $minRegexp := index $.MinVersions $task_name -}}
{{- if eq $minRegexp "" }}
  {{- $minRegexp = index $.MinVersions (printf "%s-%s" $.SuiteName $task_name) -}}
{{- end }}
{{- $excludeRegexp := index $.MaxVersions (printf "%s-%s" $.SuiteName $task_name) -}}
{{- if or (ne $minRegexp "") (ne $excludeRegexp "") }}
      - conditional-step:
  {{- if and (ne $minRegexp "") (ne $excludeRegexp "") }}
          condition-kind: and
          condition-operands:
            # Do not run on regexp version match.
            # Accounts for tests which do not exist
            # in later Juju versions.
            - condition-kind: not
              condition-operand:
                condition-kind: regex-match
                regex: "{{ $excludeRegexp }}"
                label: "{{ "${{JUJU_VERSION}}" }}"
            # Only run on regexp version match.
            # Accounts for tests which do not exist
            # until a given Juju version.
            - condition-kind: regex-match
              regex: "{{ $minRegexp }}"
              label: "{{ "${{JUJU_VERSION}}" }}"
          on-evaluation-failure: "dont-run"
          steps:
            - {{$builder}}:
                  test_name: '{{$.SuiteName}}'
                  setup_steps: ''
    {{- if gt (len $node.SkipTasks) 1 }}
                  task_name: '{{$task_name}}'
                  skip_tasks: '{{$skip_tasks}}'
    {{- else }}
                  task_name: ''
                  skip_tasks: '{{$node.ExcludedTasks}}'
    {{- end}}
  {{- else }}
        {{- if ne $excludeRegexp "" }}
          # Do not run on regexp version match.
          # Accounts for tests which do not exist
          # in later Juju versions.
          condition-kind: not
          condition-operand:
            condition-kind: regex-match
            regex: "{{ $excludeRegexp }}"
            label: "{{ "${{JUJU_VERSION}}" }}"
            on-evaluation-failure: "dont-run"
          steps:
            - {{$builder}}:
                test_name: '{{$.SuiteName}}'
                setup_steps: ''
    {{- if gt (len $node.SkipTasks) 1 }}
                task_name: '{{$task_name}}'
                skip_tasks: '{{$skip_tasks}}'
    {{- else }}
                task_name: ''
                skip_tasks: '{{$node.ExcludedTasks}}'
    {{- end}}
        {{- else }}
          # Only run on regexp version match.
          # Accounts for tests which do not exist
          # until a given Juju version.
          condition-kind: regex-match
          regex: "{{ $minRegexp }}"
          label: "{{ "${{JUJU_VERSION}}" }}"
          on-evaluation-failure: "dont-run"
          steps:
            - {{$builder}}:
                  test_name: '{{$.SuiteName}}'
                  setup_steps: ''
    {{- if gt (len $node.SkipTasks) 1 }}
                  task_name: '{{$task_name}}'
                  skip_tasks: '{{$skip_tasks}}'
    {{- else }}
                  task_name: ''
                  skip_tasks: '{{$node.ExcludedTasks}}'
    {{- end}}
        {{- end }}
  {{- end }}
{{- else }}
      - {{$builder}}:
            test_name: '{{$.SuiteName}}'
            setup_steps: ''
    {{- if gt (len $node.SkipTasks) 1 }}
            task_name: '{{$task_name}}'
            skip_tasks: '{{$skip_tasks}}'
    {{- else }}
            task_name: ''
            skip_tasks: '{{$node.ExcludedTasks}}'
    {{- end}}
{{- end }}
    publishers:
      - integration-artifacts
{{- end }}
{{- end }}
`
