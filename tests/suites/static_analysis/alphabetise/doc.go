// Package alphabetise attempts to indentify any multijobs whose subjobs
// are not listed in alphsbetical order. It does this by walking over all
// builders, jobs and job-templates looking for multi-jobs.
//
// When a multijob is found, the `name` fields of the subjobs are extracted
// and asserted to be ordered with sort.StringsAreSorted
//
package main
