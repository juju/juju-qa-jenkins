package main

import (
	"bufio"
	"fmt"
	"io/ioutil"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v2"
)

// Node represents a job inside the yaml files.
type Node struct {
	Builder struct {
		Name     string        `yaml:"name"`
		Builders []interface{} `yaml:"builders"`
	} `yaml:"builder"`
	Job struct {
		Name     string        `yaml:"name"`
		Builders []interface{} `yaml:"builders"`
	} `yaml:"job"`
	JobTemplate struct {
		Name     string        `yaml:"name"`
		Builders []interface{} `yaml:"builders"`
	} `yaml:"job-template"`
	Project struct {
		Name string        `yaml:"name"`
		Jobs []interface{} `yaml:"jobs"`
	} `yaml:"project"`
}

// Config represents the different ways to config the linter
type Config struct {
	Files struct {
		Skip []string `yaml:"skip"`
	} `yaml:"files"`
	Jobs struct {
		Ignore []string `yaml:"ignore"`
	} `yaml:"jobs"`
}

func main() {
	if len(os.Args) < 2 {
		log.Fatal("expected directory argument only.")
	}
	dir := os.Args[1]

	reader := bufio.NewReader(os.Stdin)
	bytes, err := ioutil.ReadAll(reader)
	if err != nil {
		log.Fatal("unexpected config", err)
	}
	var config Config
	if err := yaml.Unmarshal(bytes, &config); err != nil {
		log.Fatal("config parse error", err)
	}

	offeredJobNames := make(map[string]int)
	consumedJobNames := make(map[string]int)

	walkBuilders := func(builders []interface{}) {
		for _, v := range builders {
			switch v.(type) {
			case string:
				consumedJobNames[v.(string)]++
			case map[interface{}]interface{}:
				for k, v := range v.(map[interface{}]interface{}) {
					if k == "shell" || k == "inject" {
						continue
					}
					if k == "multijob" {
						multijob := v.(map[interface{}]interface{})
						names := extractMultiJobNames(multijob)
						for _, v := range names {
							consumedJobNames[v]++
						}
						continue
					}
					consumedJobNames[k.(string)]++
				}
			}
		}
	}

	walkJobs := func(jobs []interface{}) {
		for _, v := range jobs {
			switch v.(type) {
			case string:
				consumedJobNames[v.(string)]++
			case map[interface{}]interface{}:
				for k := range v.(map[interface{}]interface{}) {
					consumedJobNames[k.(string)]++
				}
			}
		}
	}

	if err := walkDirectory(dir, ignore(dir, config.Files.Skip, func(path string, info os.FileInfo) error {
		data, err := ioutil.ReadFile(path)
		if err != nil {
			return err
		}

		var job []Node
		err = yaml.Unmarshal(data, &job)
		if err != nil {
			return err
		}

		for _, v := range job {
			if v.Builder.Name != "" {
				offeredJobNames[v.Builder.Name]++
				walkBuilders(v.Builder.Builders)
				continue
			}
			if v.Job.Name != "" {
				offeredJobNames[v.Job.Name]++
				walkBuilders(v.Job.Builders)
				continue
			}
			if v.JobTemplate.Name != "" {
				offeredJobNames[v.JobTemplate.Name]++
				walkBuilders(v.JobTemplate.Builders)
				continue
			}
			if v.Project.Name != "" {
				offeredJobNames[v.Project.Name]++
				walkJobs(v.Project.Jobs)
				continue
			}
		}
		return nil
	})); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}

	// find out if there are any offeredJobNames, not consumed
	var located []string
	for offered := range offeredJobNames {
		if _, ok := consumedJobNames[offered]; !ok {
			if contains(config.Jobs.Ignore, offered) {
				continue
			}
			located = append(located, offered)
		}
	}

	sort.Strings(located)

	if len(located) > 0 {
		j, err := yaml.Marshal(struct {
			Located []string `yaml:"deadcode"`
		}{
			Located: located,
		})
		if err != nil {
			fmt.Println(err)
			os.Exit(1)
		}
		fmt.Println(string(j))
		os.Exit(2)
	}

	os.Exit(0)
}

func extractMultiJobNames(multijob map[interface{}]interface{}) []string {
	var names []string
	for k, v := range multijob {
		if k == "projects" {
			for _, v := range v.([]interface{}) {
				m := v.(map[interface{}]interface{})
				if name, ok := m["name"]; ok {
					names = append(names, name.(string))
				}
			}
		}
	}
	return names
}

func ignore(dir string, skip []string, fn func(string, os.FileInfo) error) func(string, os.FileInfo) error {
	return func(path string, info os.FileInfo) error {
		b, err := filepath.Rel(dir, path)
		if err != nil {
			return err
		}
		if contains(skip, b) {
			return nil
		}
		return fn(path, info)
	}
}

func walkDirectory(dir string, fn func(string, os.FileInfo) error) error {
	return filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || (filepath.Ext(path) != ".yml" && filepath.Ext(path) != ".yaml") {
			return nil
		}

		return fn(path, info)
	})
}

func contains(a []string, b string) bool {
	for _, v := range a {
		if strings.TrimSpace(v) == b {
			return true
		}
	}
	return false
}
