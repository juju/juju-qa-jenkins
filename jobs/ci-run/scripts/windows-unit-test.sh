#!/bin/bash
set -eux
# This is needed to ensure commands are passed properly
# Use + as % is used for env vars.
IFS='+'
ts=$(date +%s)

# Default value to non-true
PR_WINDOWS_TEST=${PR_WINDOWS_TEST:-}

# This host is setup in the ssh config in cloud-city
if [ $PR_WINDOWS_TEST ]; then
    host=cijujucharmscom-windows
else
    host=developer-win-unit-tester
fi
#Create working directory
drive="d:"
ssh $host "mkdir $drive\\payloads\\$ts"

limit=40960

runcmd() {
    echo "Running on $host as payload $ts"
    #Copy file if given
    if [[ $# -eq 2 ]] ; then
        echo "Copying $2 to $drive\\payloads\\$ts"
        scp -l $limit $2 $host:$drive\\payloads\\$ts\\
    fi
    #Make payload to run
    payload="$ts.bat"
    # Make sure we're on the right drive.
    echo "$drive" > $payload
    echo "cd $drive\\payloads\\$ts" >> $payload
    echo "$1" >> $payload
    #Ensure the error is returned if the command fails
    echo "if errorlevel 1 (" >> $payload
    echo "   exit /b %errorlevel%" >> $payload
    echo ")" >> $payload
    scp -l $limit $payload $host:$drive\\payloads\\
    #Run test command via ssh
    ssh $host $drive\\payloads\\$payload
}

function cleanup {
    # Grab test output from windows, parse it
    scp -l $limit -T $host:$drive\\payloads\\$ts\\go-unitest.out ${WORKSPACE}/go-unittest.out
    export GOPATH=/var/lib/jenkins/gopath
    GO111MODULE=off go get github.com/tebeka/go2xunit
    ${GOPATH}/bin/go2xunit -fail -input ${WORKSPACE}/go-unittest.out -output ${WORKSPACE}/tests.xml

    # cleanup any lingering mongodb or juju
    cmd="cleanup"
    echo "taskkill /F /T /FI \"STATUS eq RUNNING\" /IM juju*" >> $cmd
    echo "taskkill /F /T /FI \"STATUS eq RUNNING\" /IM mongo*" >> $cmd
    runcmd $(cat $cmd)
}

trap cleanup EXIT

tarfile=$(basename ${WORKSPACE}/juju-source*.tar.xz)
if [ $PR_WINDOWS_TEST ]; then
    # move the raw juju vendored source code to the right location
    tarfile="juju-source-${PR_WINDOWS_DATE}.tar.xz"
    mv "${WORKSPACE}/raw-juju-source-vendor-${PR_WINDOWS_DATE}.tar.xz" "$tarfile" || true
fi

# cmd will become a long script to pass through to run. . .

powershell="powershell.exe -Command"
godownload="installgo.ps1"
cmd="payload"
# make temp dir nah
echo "echo \$downloadDir = \$env:TEMP > $godownload" > $cmd
echo "echo \$packageName = 'golang' >> $godownload" >> $cmd
echo "echo \$url = 'https://storage.googleapis.com/golang/go$GOVERSION.windows-amd64.zip' >> $godownload" >> $cmd
echo "echo \$goroot = 'C:\\go' >> $godownload" >> $cmd
echo "echo \$zip = \"\$downloadDir\\golang-$GOVERSION.zip\" >> $godownload" >> $cmd
echo "echo if (!(Test-Path \"\$zip\")) { >> $godownload" >> $cmd
echo "echo   \$downloader = new-object System.Net.WebClient >> $godownload" >> $cmd
echo "echo   \$downloader.DownloadFile(\$url, \$zip) >> $godownload" >> $cmd
echo "echo } >> $godownload" >> $cmd
echo "echo if (Test-Path \"\$goroot\") { >> $godownload" >> $cmd
echo "echo   rm -Force -Recurse -Path \"\$goroot\" >> $godownload" >> $cmd
echo "echo } >> $godownload" >> $cmd
echo "echo if (Test-Path \"\$downloadDir\\go\") { >> $godownload" >> $cmd
echo "echo   rm -Force -Recurse -Path \"\$downloadDir\\go\" >> $godownload" >> $cmd
echo "echo } >> $godownload" >> $cmd
echo "echo Add-Type -AssemblyName System.IO.Compression.FileSystem >> $godownload" >> $cmd
echo "echo [System.IO.Compression.ZipFile]::ExtractToDirectory(\"\$zip\", \$downloadDir) >> $godownload" >> $cmd
echo "echo mv \"\$downloadDir\\go\" \$goroot >> $godownload" >> $cmd
echo "powershell.exe -noprofile -noninteractive .\\$godownload"  >> $cmd
echo "mkdir build" >> $cmd
echo "move juju-source*.tar.xz build" >> $cmd
echo "cd build" >> $cmd
echo "7z x juju-source*.tar.xz" >> $cmd
echo "del juju-source*.tar.xz" >> $cmd
echo "7z x juju-source*.tar" >> $cmd
echo "del juju-source*.tar" >> $cmd
echo "set GOPATH=%cd%" >> $cmd
echo "cd .." >> $cmd
echo "set GOARCH=amd64" >> $cmd
echo "set CGO_ENABLED=0" >> $cmd
# For some reason need to remove openssh from path.
echo "set PATH=%PATH:C:\\Program Files\\OpenSSH-Win64;=%" >> $cmd
echo "$powershell go.exe env" >> $cmd
echo "$powershell go.exe version" >> $cmd
echo "$powershell go.exe clean -cache" >> $cmd
echo "$powershell mongod --version" >> $cmd
echo "cd build\\src\\github.com\\juju\\juju" >> $cmd
echo "IF EXIST \"go.mod\" (" >> $cmd
echo "  cd cmd" >> $cmd
echo "  $powershell go.exe test -mod=vendor -v -timeout=1200s ./... > $drive\\payloads\\$ts\\go-unitest.out" >> $cmd
echo ") ELSE (" >> $cmd
echo "  cd cmd" >> $cmd
echo "  $powershell go.exe test -v -timeout=1200s ./... > $drive\\payloads\\$ts\\go-unitest.out" >> $cmd
echo ")" >> $cmd
echo "type $drive\\payloads\\$ts\\go-unitest.out" >> $cmd

runcmd $(cat $cmd) $tarfile
