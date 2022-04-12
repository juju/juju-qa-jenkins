// Package simplify attempts to simplify the yaml found with in the jobs folder.
// It does this by walking of the nodes where possible and see if there are
// any complicated structures that aren't required.
//
// Currently it will attempt to see if there are any multijobs with one project,
// when that singular project can just be run as a leaf project.
// Simplifying the nested jobs helps with readibility as circular dependencies
// can cause unwanted side effects.
//
// A config file can be told which files to ignore along with which resulting
// jobs to ignore once parsed.
//
package main
