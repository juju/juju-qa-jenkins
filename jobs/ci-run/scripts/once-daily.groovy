import hudson.model.*

def desc = build.getDescription().split(":")
def jujuVersion = desc[0]
def jujuVersionExploded = []
for (v in jujuVersion.split(/[.]/)) {
    jujuVersionExploded.push(v)
}
if (jujuVersionExploded.size() > 3 || jujuVersionExploded[1].indexOf("-") != -1) {
    jujuVersionExploded.pop()
}
jujuVersion = jujuVersionExploded.join(".")

println "Looking for $jujuVersion in previous builds..."

def b = build.getPreviousBuild()
while (b != null) {
    if (b.result != Result.SUCCESS || b.getDescription() == null || b.getDescription().indexOf(jujuVersion) == -1) {
        b = b.getPreviousBuild()
        continue
    }
    if (b.getStartTimeInMillis()+(24*60*60*1000)>build.getStartTimeInMillis()) {
        println "Found previous build less than a day ago ${b.getAbsoluteUrl()}"
        throw new InterruptedException()
    }
    break
}

println "It has been one day since last build... triggering job"