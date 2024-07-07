
import hudson.model.*
import jenkins.model.Jenkins
import org.jenkinsci.plugins.envinject.EnvInjectPluginAction

def pr = build.getEnvironment(listener).get("ghprbPullLink")
def goversion = build.getEnvironment(listener).get("GOVERSION")
def mergecommit = build.getEnvironment(listener).get("MERGE_COMMIT")
def b = Jenkins.getInstance().getItem("github-make-check-juju").getLastBuild()
def limit = 100
while (b != null && limit > 0) {
    def current = b
    limit = limit - 1
    b = b.getPreviousBuild()
    if (current.result == null) {
        continue
    }
    if (current.result != Result.SUCCESS) {
        continue
    }
    def vars = current.buildVariableResolver
    println "${vars.resolve("ghprbPullLink")} ${vars.resolve("GOVERSION")} ${vars.resolve("MERGE_COMMIT")}"
    if (vars.resolve("ghprbPullLink").equals(pr) &&
        vars.resolve("GOVERSION").equals(goversion) &&
        vars.resolve("MERGE_COMMIT").equals(mergecommit)) {
        println "Found previous successful build ${current.getAbsoluteUrl()} with the same parameters"
        build.getAction(EnvInjectPluginAction.class).overrideAll([SKIP_CHECK: '1'])
        break
    }
}