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
	"strconv"
	"strings"
	"text/template"

	"github.com/schollz/progressbar/v3"
	"gopkg.in/yaml.v2"
	"mvdan.cc/sh/v3/syntax"
)

// Config represents the configuration for gen-wire-tests.
type Config struct {
	Folders struct {
		Skip     []string `yaml:"skip-all"`
		LXD      []string `yaml:"lxd"`
		AWS      []string `yaml:"aws"`
		Google   []string `yaml:"google"`
		Azure    []string `yaml:"azure"`
		Microk8s []string `yaml:"microk8s"`
		// ExcludeTasks maps cloud name to suite-subtask pairs that
		// should be excluded from that cloud's jobs even when the
		// parent suite is allowed. e.g. "controller-test_limit_access"
		ExcludeTasks map[string][]string       `yaml:"exclude-tasks"`
		SkipSubTasks []string                  `yaml:"skip-subtasks"`
		PreventSplit []string                  `yaml:"prevent-split"`
		Ephemeral    []string                  `yaml:"ephemeral"`
		CrossCloud   []string                  `yaml:"cross-cloud"`
		Timeout      map[string]map[string]int `yaml:"timeout"`
		Introduced   map[string]string         `yaml:"introduced"`
		Removed      map[string]string         `yaml:"removed"`
	}
}

// BranchSuites holds the collected suite and subtask names for a
// branch, as written by the collect command.
type BranchSuites struct {
	// Suites maps suite name to its ordered list of subtask names.
	Suites map[string][]string `yaml:"suites"`
}

// Task holds the resolved job configuration for a single test suite.
type Task struct {
	Clouds             []Cloud
	SubTasks           []string
	ExcludedTasks      []string
	ExcludedCloudTasks map[string][]string
	Timeout            map[string]int
}

// Cloud describes a target cloud for integration testing.
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

// allClouds is the ordered list of all supported clouds.
var allClouds = []Cloud{aws, azure, google, lxd, microk8s}

// Override repoOrg when testing on personal branches.
const repoOrg = "juju"

// branchVersion pairs a GitHub branch name with the Juju version it
// tracks.
type branchVersion struct {
	Branch  string
	Version string
}

// branches is the ordered list of Juju repo branches to collect and
// generate from, in ascending version order.
var branches = []branchVersion{
	{Branch: "3.6", Version: "3.6"},
	{Branch: "4.0", Version: "4.0"},
	{Branch: "main", Version: "4.1"},
}

// main dispatches to the collect or generate subcommand.
func main() {
	if len(os.Args) < 2 {
		log.Fatal("expected command: collect or generate")
	}
	switch os.Args[1] {
	case "collect":
		cmdCollect(os.Args[2:])
	case "generate":
		cmdGenerate(os.Args[2:])
	default:
		log.Fatalf(
			"unknown command %q, expected collect or generate",
			os.Args[1],
		)
	}
}

// cmdCollect fetches test suite and subtask information from GitHub for
// each known branch and writes it to a YAML file per branch in the
// given output directory (e.g. 3.6.yaml, main.yaml).
func cmdCollect(args []string) {
	if len(args) < 1 {
		log.Fatal("collect: expected output directory argument")
	}
	outputDir := args[0]
	if err := os.MkdirAll(outputDir, os.ModePerm); err != nil {
		log.Fatalf("collect: unable to create output dir: %v", err)
	}

	for _, bv := range branches {
		suiteInfo := fetchSuitesFromRepo(bv.Branch)

		pb := progressbar.NewOptions(
			len(suiteInfo),
			progressbar.OptionUseANSICodes(false),
			progressbar.OptionShowElapsedTimeOnFinish(),
			progressbar.OptionSetWidth(50),
			progressbar.OptionSetDescription(
				fmt.Sprintf("Collecting %s...", bv.Branch),
			),
			progressbar.OptionSetTheme(progressbar.Theme{
				Saucer:        "=",
				SaucerHead:    ">",
				SaucerPadding: " ",
				BarStart:      "[",
				BarEnd:        "]",
			}),
		)

		collected := BranchSuites{
			Suites: make(map[string][]string, len(suiteInfo)),
		}
		for _, dir := range suiteInfo {
			pb.Add(1)
			collected.Suites[dir.Name] = parseTaskNames(dir)
		}
		_ = pb.Exit()
		fmt.Println()

		data, err := yaml.Marshal(collected)
		if err != nil {
			log.Fatalf(
				"collect: unable to marshal branch %q: %v",
				bv.Branch, err,
			)
		}
		outputPath := filepath.Join(outputDir, bv.Branch+".yaml")
		if err := os.WriteFile(outputPath, data, 0644); err != nil {
			log.Fatalf(
				"collect: unable to write %q: %v",
				outputPath, err,
			)
		}
		log.Printf("Written %s", outputPath)
	}
}

// cmdGenerate reads collected branch YAML files from suitesDir and a
// config from stdin, then writes Jenkins job definition YAML files to
// outputDir.
func cmdGenerate(args []string) {
	if len(args) < 2 {
		log.Fatal(
			"generate: expected suites directory and output directory",
		)
	}
	suitesDir := args[0]
	outputDir := args[1]

	if outDir, err := os.Open(outputDir); os.IsNotExist(err) {
		if err := os.MkdirAll(outputDir, os.ModePerm); err != nil {
			log.Fatal("unable to create output dir", outputDir)
		}
	} else {
		log.Printf(
			"Warning: Output directory %q already exists."+
				" It may overwrite files!\n",
			outputDir,
		)
		// Remove all yaml files so that git can track deletions too.
		outFiles, err := outDir.Readdirnames(0)
		if err != nil {
			log.Fatalf(
				"unable to read output dir files: %v\n "+
					"If you are having an issue reading from stdin,"+
					" check your terminal is not part of a strictly"+
					" confined snap (e.g. an built-in IDE terminal)",
				err,
			)
		}
		for _, f := range outFiles {
			if !strings.HasSuffix(f, ".yml") {
				continue
			}
			if err := os.Remove(filepath.Join(outputDir, f)); err != nil {
				log.Fatalf(
					"unable to remove existing file %q: %v", f, err,
				)
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

	branchTests := make([]map[string]Task, len(branches))
	for i, bv := range branches {
		bs := readBranchSuites(
			filepath.Join(suitesDir, bv.Branch+".yaml"),
		)
		branchTests[i] = buildTestsFromSuites(config, bs)
	}

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
	t := template.Must(
		template.New("integration").Funcs(funcMap).Parse(Template),
	)

	// Merge in version order. Later branches overwrite earlier ones.
	// A suite absent from the next branch is marked removed at that
	// next branch's version.
	allTests := make(map[string]Task)
	for i := range branches {
		for suiteName, task := range branchTests[i] {
			allTests[suiteName] = task
		}
		if i+1 < len(branches) {
			next := branches[i+1]
			for suiteName := range branchTests[i] {
				if _, ok := branchTests[i+1][suiteName]; !ok {
					config.Folders.Removed[suiteName] = next.Version
				}
			}
		}
	}

	for suiteName, task := range allTests {
		writeJobDefinitions(t, config, outputDir, task, suiteName)
	}
}

// readBranchSuites reads a branch YAML file produced by cmdCollect.
func readBranchSuites(path string) BranchSuites {
	data, err := os.ReadFile(path)
	if err != nil {
		log.Fatalf(
			"unable to read branch suites file %q: %v", path, err,
		)
	}
	var bs BranchSuites
	if err := yaml.Unmarshal(data, &bs); err != nil {
		log.Fatalf(
			"unable to parse branch suites file %q: %v", path, err,
		)
	}
	return bs
}

// buildTestsFromSuites applies config to a BranchSuites and returns
// the resulting Task map. It replaces the old fetchTestsFromRepo, with
// the GitHub-fetching part moved to cmdCollect.
func buildTestsFromSuites(
	config Config,
	bs BranchSuites,
) map[string]Task {
	testSuites := make(map[string]Task)
	for suiteName, subTaskNames := range bs.Suites {
		if contains(config.Folders.Skip, suiteName) {
			continue
		}

		taskNames := []string{suiteName}
		excluded := []string{}
		excludedCloudTasks := make(map[string][]string)
		if !contains(config.Folders.PreventSplit, suiteName) {
			taskNames = []string{}
			for _, subTask := range subTaskNames {
				if !contains(config.Folders.SkipSubTasks, subTask) {
					taskNames = append(taskNames, subTask)
				} else {
					excluded = append(excluded, subTask)
				}
				fullName := suiteName + "-" + subTask
				for _, cloud := range allClouds {
					if contains(
						config.Folders.ExcludeTasks[cloud.Name],
						fullName,
					) {
						excludedCloudTasks[cloud.Name] = append(
							excludedCloudTasks[cloud.Name], subTask,
						)
					}
				}
			}
		}

		clouds := make([]Cloud, 0)
		if matchesList(config.Folders.AWS, suiteName) {
			clouds = append(clouds, aws)
		}
		if matchesList(config.Folders.Azure, suiteName) {
			clouds = append(clouds, azure)
		}
		if matchesList(config.Folders.Google, suiteName) {
			clouds = append(clouds, google)
		}
		if matchesList(config.Folders.LXD, suiteName) {
			clouds = append(clouds, lxd)
		}
		if matchesList(config.Folders.Microk8s, suiteName) {
			clouds = append(clouds, microk8s)
		}

		if len(clouds) == 0 {
			continue
		}

		testSuites[suiteName] = Task{
			Clouds:             clouds,
			SubTasks:           taskNames,
			ExcludedTasks:      excluded,
			ExcludedCloudTasks: excludedCloudTasks,
			Timeout:            config.Folders.Timeout[suiteName],
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
	outputPath := filepath.Join(
		outputDir, fmt.Sprintf("test-%s.yml", suiteName),
	)
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
	for _, subTask := range task.SubTasks {
		if introduced, ok := config.Folders.Introduced[subTask]; ok {
			minVersions[subTask] = buildMinVersionRegex(introduced)
		}
		if introduced, ok := config.Folders.Introduced[suiteName+"-"+subTask]; ok {
			minVersions[suiteName+"-"+subTask] = buildMinVersionRegex(introduced)
		}
		if introduced, ok := config.Folders.Introduced[suiteName]; ok {
			minVersions[suiteName+"-"+subTask] = buildMinVersionRegex(introduced)
		}
		if removed, ok := config.Folders.Removed[suiteName+"-"+subTask]; ok {
			maxVersions[suiteName+"-"+subTask] = buildMinVersionRegex(removed)
		}
		if removed, ok := config.Folders.Removed[suiteName]; ok {
			maxVersions[suiteName+"-"+subTask] = buildMinVersionRegex(removed)
		}
	}

	if err := t.Execute(f, struct {
		SuiteName          string
		Clouds             []Cloud
		TaskNames          []string
		SkipTasks          []string
		ExcludedTasks      string
		ExcludedCloudTasks map[string][]string
		Ephemeral          map[string]bool
		CrossCloud         map[string]bool
		Timeout            map[string]int
		MinVersions        map[string]string
		MaxVersions        map[string]string
	}{
		SuiteName:          suiteName,
		Clouds:             task.Clouds,
		TaskNames:          task.SubTasks,
		SkipTasks:          joined,
		ExcludedTasks:      strings.Join(task.ExcludedTasks, ","),
		ExcludedCloudTasks: task.ExcludedCloudTasks,
		Ephemeral:          ephemeral,
		CrossCloud:         crossCloud,
		Timeout:            task.Timeout,
		MinVersions:        minVersions,
		MaxVersions:        maxVersions,
	}); err != nil {
		log.Fatalf(
			"unable to execute template %q with error %v",
			suiteName, err,
		)
	}
	f.Sync()
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
		req.Header.Add(
			"Authorization", fmt.Sprintf("Bearer %s", token),
		)
	}
	resp, err := client.Do(req)
	if err != nil {
		log.Fatalf("unable to fetch URL %q: %v", url, err)
	}
	if resp.StatusCode != 200 {
		log.Fatalf(
			"unable to fetch URL %q; status code %d",
			url, resp.StatusCode,
		)
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Fatalf("unable to get URL %q content: %v", url, err)
	}
	var ghObjects []ghObject
	err = json.Unmarshal(data, &ghObjects)
	if err != nil {
		log.Fatalf(
			"unable to unmarshal URL %q content: %v", url, err,
		)
	}
	return ghObjects, nil
}

func fetchSuitesFromRepo(branch string) []ghObject {
	url := fmt.Sprintf(
		"https://api.github.com/repos/%s/juju/contents/tests/suites?ref=%s",
		repoOrg, branch,
	)
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

func parseTaskNames(dir ghObject) []string {
	tasks := make(map[string]int)

	ghObjects, err := fetchGithubObjects(dir.URL)
	if err != nil {
		log.Fatalf(
			"unable to fetch test suite %q files: %v", dir.Name, err,
		)
	}

	for _, f := range ghObjects {
		if !strings.HasSuffix(f.Name, ".sh") {
			continue
		}

		req, _ := http.NewRequest("GET", f.DownloadURL, nil)
		token := os.Getenv("GH_TOKEN")
		if token != "" {
			req.Header.Add(
				"Authorization", fmt.Sprintf("Bearer %s", token),
			)
		}

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			log.Fatalf(
				"unable to get test file %q context: %v", f.Name, err,
			)
		}
		if resp.StatusCode != 200 {
			_ = resp.Body.Close()
			log.Fatalf(
				"unable to get test file %q context; status code: %d",
				f.Name, resp.StatusCode,
			)
		}

		parser := syntax.NewParser(syntax.Variant(syntax.LangBash))
		prog, err := parser.Parse(resp.Body, "task.sh")
		if err != nil {
			_ = resp.Body.Close()
			log.Fatalf(
				"unable to parse test suite task content with error %v",
				err,
			)
		}
		_ = resp.Body.Close()
		syntax.Walk(prog, func(node syntax.Node) bool {
			switch t := node.(type) {
			case *syntax.FuncDecl:
				// Capture the name of the function.
				if !strings.HasPrefix(t.Name.Value, "test_") {
					return true
				}

				// Traverse the function body to ensure that anything
				// with test is called.
				if _, ok := tasks[t.Name.Value]; !ok {
					tasks[t.Name.Value] = 1
				} else {
					tasks[t.Name.Value]++
				}

				syntax.Walk(t.Body, func(node syntax.Node) bool {
					switch t := node.(type) {
					case *syntax.CallExpr:
						// We're not interested in items called outside
						// of our function case.
						if len(t.Args) == 0 {
							return true
						}
						for _, arg := range t.Args {
							lit, ok := arg.Parts[0].(*syntax.Lit)
							if !ok || !strings.HasPrefix(
								lit.Value, "test_",
							) {
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

// buildMinVersionRegex returns a regexp string that matches any Juju
// version >= the given "major.minor" version string. The returned
// string uses JJB-style brace escaping ({{, }}) and is suitable for
// direct insertion into a Jenkins job builder YAML template.
//
// For a version M.N it matches:
//   - any version with major > M; or
//   - major == M with a single-digit minor >= N, or any 2+ digit minor.
func buildMinVersionRegex(version string) string {
	majStr, minStr, ok := strings.Cut(version, ".")
	if !ok {
		log.Fatalf(
			"buildMinVersionRegex: invalid version %q", version,
		)
	}
	maj, err := strconv.Atoi(majStr)
	if err != nil {
		log.Fatalf(
			"buildMinVersionRegex: invalid major in %q: %v",
			version, err,
		)
	}
	min, err := strconv.Atoi(minStr)
	if err != nil {
		log.Fatalf(
			"buildMinVersionRegex: invalid minor in %q: %v",
			version, err,
		)
	}
	return fmt.Sprintf(
		"^[%d-9].*|^%d\\\\.([%d-9]|\\\\d{{2,}})(\\\\.|-).*",
		maj+1, maj, min,
	)
}

func contains(haystack []string, needle string) bool {
	for _, skip := range haystack {
		if needle == skip {
			return true
		}
	}
	return false
}

// matchesList returns true if name matches any entry in list. Entries
// may contain '*' as a glob wildcard (e.g. "*_k8s").
func matchesList(list []string, name string) bool {
	for _, pattern := range list {
		if !strings.Contains(pattern, "*") {
			if pattern == name {
				return true
			}
			continue
		}
		matched, err := filepath.Match(pattern, name)
		if err == nil && matched {
			return true
		}
	}
	return false
}

// Template is the integration test configuration template for Jenkins
// job builder.
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
        {{- if (contains (index $node.ExcludedCloudTasks $cloud.Name) $task_name) }}
          {{- continue }}
        {{- end }}
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
{{- if (contains (index $node.ExcludedCloudTasks $cloud.Name) $task_name) }}
  {{- continue }}
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
{{- if eq $.SuiteName "cmr" }}
      - install-go
{{- end }}
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
