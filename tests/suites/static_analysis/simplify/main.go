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

	locateSingleMultijobs := func(builders []interface{}) (string, bool) {
		for _, builder := range builders {
			switch builder.(type) {
			case map[interface{}]interface{}:
				for k, v := range builder.(map[interface{}]interface{}) {
					if k == "shell" || k == "inject" {
						continue
					}
					if k == "multijob" {
						multijob := v.(map[interface{}]interface{})
						names := extractMultiProjects(multijob)
						if len(names) == 1 {
							return multijob["name"].(string), true
						}
					}
				}
			}
		}
		return "", false
	}

	var simpleMultijobs []string

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
				if name, ok := locateSingleMultijobs(v.Builder.Builders); ok {
					simpleMultijobs = append(simpleMultijobs, fmt.Sprintf("%s:%s", v.Builder.Name, name))
				}
				continue
			}
			if v.Job.Name != "" {
				if name, ok := locateSingleMultijobs(v.Job.Builders); ok {
					simpleMultijobs = append(simpleMultijobs, fmt.Sprintf("%s:%s", v.Job.Name, name))
				}
				continue
			}
			if v.JobTemplate.Name != "" {
				if name, ok := locateSingleMultijobs(v.JobTemplate.Builders); ok {
					simpleMultijobs = append(simpleMultijobs, fmt.Sprintf("%s:%s", v.JobTemplate.Name, name))
				}
				continue
			}
		}
		return nil
	})); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}

	sort.Strings(simpleMultijobs)

	var results []string
	for _, job := range simpleMultijobs {
		if contains(config.Jobs.Ignore, job) {
			continue
		}
		results = append(results, job)
	}

	if len(results) > 0 {
		j, err := yaml.Marshal(struct {
			Simplify []string `yaml:"simplify"`
		}{
			Simplify: results,
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

func extractMultiProjects(multijob map[interface{}]interface{}) []string {
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
