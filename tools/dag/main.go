package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io/ioutil"
	"log"
	"os"
	"path/filepath"
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

	root := NewDAG()

	walkBuilders := func(builders []interface{}, node *DagNode) {
		for _, v := range builders {
			switch v.(type) {
			case string:
				node.AddEdge(v.(string))
			case map[interface{}]interface{}:
				for k, v := range v.(map[interface{}]interface{}) {
					if k == "shell" || k == "inject" {
						continue
					}
					if k == "multijob" {
						multijob := v.(map[interface{}]interface{})
						names := extractMultiJobNames(multijob)
						for _, v := range names {
							node.AddEdge(v)
						}
						continue
					}
					node.AddEdge(k.(string))
				}
			}
		}
	}

	walkJobs := func(jobs []interface{}, node *DagNode) {
		for _, v := range jobs {
			switch v.(type) {
			case string:
				node.AddEdge(v.(string))
			case map[interface{}]interface{}:
				for k := range v.(map[interface{}]interface{}) {
					node.AddEdge(k.(string))
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
				walkBuilders(v.Builder.Builders, root.AddVertex(v.Builder.Name))
				continue
			}
			if v.Job.Name != "" {
				walkBuilders(v.Job.Builders, root.AddVertex(v.Job.Name))
				continue
			}
			if v.JobTemplate.Name != "" {
				walkBuilders(v.JobTemplate.Builders, root.AddVertex(v.JobTemplate.Name))
				continue
			}
			if v.Project.Name != "" {
				walkJobs(v.Project.Jobs, root.AddVertex(v.Project.Name))
				continue
			}
		}
		return nil
	})); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}

	fmt.Println(root.Render())
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

type Dag struct {
	nodes map[string]*DagNode
}

func NewDAG() *Dag {
	root := new(Dag)
	root.nodes = make(map[string]*DagNode)
	return root
}

func (d *Dag) AddVertex(name string) *DagNode {
	node := new(DagNode)
	node.name = name
	d.nodes[name] = node
	return node
}

func (d *Dag) Render() string {
	template := `
digraph depgraph {
	rankdir=LR;`
	nodes := make([]string, len(d.nodes))
	for _, node := range d.nodes {
		b := new(bytes.Buffer)
		node.Render(b)
		nodes = append(nodes, b.String())
	}
	return fmt.Sprintf("%s\n%s}", template, strings.Join(nodes, ""))
}

type Writer interface {
	WriteString(string) (int, error)
}

type DagNode struct {
	name     string
	children []string
}

func (n *DagNode) AddEdge(to string) {
	n.children = append(n.children, to)
}

func (n *DagNode) Render(b Writer) {
	if len(n.children) == 0 {
		b.WriteString(fmt.Sprintf("\t\"%s\"\n", n.name))
		return
	}

	for _, v := range n.children {
		b.WriteString(fmt.Sprintf("\t\"%s\" -> \"%s\"\n", n.name, v))
	}
}
