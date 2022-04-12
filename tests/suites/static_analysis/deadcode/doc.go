// Package deadcode attempts to identify any orphan jobs that have no relation
// to any other job. It does this by walking over all the builders, jobs,
// job-templates and projects to see what jobs are offered and then checks all
// the jobs to see which jobs are also consumed.
//
// The deadcode only checks that all jobs are consumed and any that aren't
// consumed are considered orphaned.
// The algorithm is simplistic at best and a better topoligical graph would be
// better, but also over engineered, as we just want to give a hint to what
// is found in the job folder and ensure things are correctly wired up.
//
package main
