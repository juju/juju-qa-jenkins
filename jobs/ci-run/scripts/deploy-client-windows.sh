#!/bin/bash
set -eux
# This is needed to ensure commands are passed properly
# Use + as % is used for env vars.
IFS='+'

runcmd() {
    host=$1
    ts=$(date +%s)
    drive="D:"
    echo "Running on $host as payload $ts"
    #Create working directory
    ssh $host "mkdir $drive\\payloads\\$ts"
    ssh $host "mkdir $drive\\user-tmp" || true
    #Copy file if given
    if [[ $# -eq 3 ]] ; then
        echo "Copying $3 to $drive\\payloads\\$ts"
        scp $3 $host:$drive\\payloads\\$ts\\
    fi
    #Make payload to run
    payload="$ts.bat"
    echo "$drive" > $payload
    echo "cd $drive\\payloads\\$ts" >> $payload
    echo "$2" >> $payload
    #Ensure the error is returned if the command fails
    echo "if errorlevel 1 (" >> $payload
    echo "   exit /b %errorlevel%" >> $payload
    echo ")" >> $payload
    scp $payload $host:$drive\\payloads\\
    #Run test command via ssh
    ssh $host $drive\\payloads\\$payload
}

function cleanup {
    # cleanup any lingering mongodb or juju
    cmd="cleanup"
    echo "taskkill /F /T /FI \"STATUS eq RUNNING\" /IM juju*" >> $cmd
    echo "taskkill /F /T /FI \"STATUS eq RUNNING\" /IM mongo*" >> $cmd
    runcmd developer-win-unit-tester $(cat $cmd)
}

trap cleanup EXIT

cmd='payload'
# For some reason need to remove openssh from path.
echo "set PATH=%PATH:C:\\Program Files\\OpenSSH-Win64;=%" >> $cmd
echo "juju.exe version" >> $cmd
echo "juju.exe unregister aws -y" >> $cmd
echo "juju.exe bootstrap aws aws --debug --config agent-metadata-url=https://ci-run-streams.s3.amazonaws.com/builds/build-${SHORT_GIT_COMMIT}/ --config agent-stream=build-${SHORT_GIT_COMMIT}"  >> $cmd
echo "juju.exe deploy ubuntu" >> $cmd
# we want a 10 second timeout before calling status and the default "TIMEOUT"
# command doesn't work headless, so we fall back to pinging localhost with a
# delay. This seems to be the suggested work around.
echo "ping -n 10 127.0.0.1 >NUL" >> $cmd
echo "juju.exe status" >> $cmd
echo "juju.exe kill-controller aws -y" >> $cmd

runcmd developer-win-unit-tester $(cat $cmd) ${WORKSPACE}/build/juju.exe
