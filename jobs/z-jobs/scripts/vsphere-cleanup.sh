#!/bin/bash

## vsphere-cleanup.sh
##
## Terminates any vSphere instances over $HOURS hours old.
set -e

# set some defaults:
HOURS=4
VERBOSE=true
NOW=$(date +%s)

# These variables, hold the name of the credential variables we want for
# cleaning a specific vsphere cloud.  The credential variables are created
# in parse_yaml below.
user=credentials_${VSPHERE_NAME}_credentials_user
password=credentials_${VSPHERE_NAME}_credentials_password
default_region=credentials_${VSPHERE_NAME}_defaultregion

# grep criterial for eval of parse_yaml later
search=^credentials_${VSPHERE_NAME}_

# load our access credentials
CREDENTIALS=
for file in $JUJU_DATA/credentials.yaml \
       $JUJU_DATA/credentials.yaml; do
    if [ -f "$file" ]; then
        CREDENTIALS=$file
        break
    fi
done

# parse the credentials.yaml file to avoid having an rc file, requiring
# password changes in the like in multiple places.
parse_yaml() {
    local s='[[:space:]]*' w='[-a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
    sed -ne "s|^\($s\):|\1|" \
         -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
         -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  "$1" |
    awk -F"$fs" '{
        indent = length($1)/2;
        vname[indent] = $2;
        for (i in vname) {if (i > indent) {delete vname[i]}}
        if (length($3) > 0) {
            vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
            printf("%s%s='"'"'%s'"'"'\n", vn, $2, $3);
        }
    }' |
    sed ':b; s/^\([^=]*\)-/\1/; tb'
}

eval $(parse_yaml $CREDENTIALS | grep ${search})
export GOVC_USERNAME=${GOVC_USERNAME:-${!user}}
export GOVC_PASSWORD=${GOVC_PASSWORD:-${!password}}
export GOVC_URL=${GOVC_URL:-${VSPHERE_SDK_URL}}
export GOVC_DATACENTER=${GOVC_DATACENTER:-${!default_region}}
export GOVC_INSECURE=${GOVC_INSECURE:-1}

# make sure we have the cli tool
govc="govc_linux_amd64"
if ! which $govc >/dev/null; then
    echo "WARNING: VMware vSphere govc CLI Tool not installed. Installing."
    (
        cd /tmp
        govmomirepo="vmware/govmomi/releases"
        url=$(curl -s https://api.github.com/repos/$govmomirepo/latest |
                  jq -r ".assets[]
            | select(.name  | contains(\"$govc\"))
            | .browser_download_url")
        curl -s -LO "$url"
        gunzip -f $govc.gz
        chmod +x $govc
        sudo mv $govc /usr/local/bin/
    )
fi

$VERBOSE && echo ""
$VERBOSE && echo "Datacenter Info:"
$govc datacenter.info
$VERBOSE && echo ""
$VERBOSE && echo "Datastore Info:"
$govc ls -l=true /${GOVC_DATACENTER}/datastore | awk '{print $1}' | grep -v folder  | xargs $govc datastore.info

function destroy_old_vms() {
    pattern=$1
    $VERBOSE && echo ""
    $VERBOSE && echo "-> Finding VMs to destroy with pattern: $pattern"
    paths=`$govc find $pattern -type m -name "juju-*" -runtime.powerState poweredOn`

    # Allow the for loop to handle input with the spaces.
    IFS=$'\n'

    for path in $paths;do
        # example of each path:
        # /QA/vm/CITestFolder/Juju Controller (f341d1fd-566d-4be9-85cf-06d73b25dc9c)/Model "default" (0170bf3a-fce5-448c-8a61-3682ea5074c1)/juju-5074c1-0

	# Get the name of the controller folder to delete it if the VM is destroyed.
        controller=`echo $path | cut -d '/' -f 5`

	# Get the VM name to destroy it if needed.
        id=`echo $path | cut -d '/' -f 7`

	# Has the VM been alive for more than time allowed?
        out=`$govc vm.info --json $id | jq "select( $NOW - (.VirtualMachines[].Config.ChangeVersion | strptime(\"%Y-%m-%dT%H:%M:%S%Z\") | mktime ) > ($HOURS * 3600) )" || true `
        if [ -n "${out}" ]
        then
            $VERBOSE && echo "Found VM $id"
            $VERBOSE && echo "  More than $HOURS hours old. Deleting."
            $govc vm.destroy "$id"

	    # Delete the folder at a high level to include templates etc.
            $VERBOSE && echo "-> Deleting folders like $controller, will fail if more associated vms to destroy"
            $govc object.destroy "$controller" || true
	else 
            $VERBOSE && echo "Skipping VM $id and folder $controller"
        fi
    done
}

destroy_old_vms "/${GOVC_DATACENTER}/vm/${VSPHERE_FOLDER}"

$VERBOSE && echo ""
$VERBOSE && echo "->Folders, templates and vms left behind"
$VERBOSE && $govc find "/${GOVC_DATACENTER}/vm/${VSPHERE_FOLDER}"


