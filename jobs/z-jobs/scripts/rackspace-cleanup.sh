#!/bin/bash

## rackspace-cleanup.sh
##
## Terminates any Rackspace instances over $HOURS hours old.
## Uses the openstack CLI.
## Note that some instances have a "permanent" tag in the Web UI but I
## cannot find a way to retrieve instance tags from the command line.
## Instead we restrict any operations to instances named juju-*.

# set some defaults:
HOURS=12
VERBOSE=true
TIMEOUT="timeout -s INT 3m"
NOW=$(date +%s)

# verify we have the cli tools installed
if ! which openstack >/dev/null; then
    echo "WARNING: openstack client required for Rackspace. Installing."
    sudo DEBIAN_FRONTEND=noninteractive apt install -y python-openstackclient
fi

# Rackspace has 6 regions.
# Hardcoded here but they don't change very often.

for region in DFW IAD ORD LON SYD HKG; do
    export OS_REGION_NAME=$region
    $VERBOSE && echo "Scanning region $region"
    # iterate over all the instances
    for instanceid in $($TIMEOUT openstack server list -c ID -f value); do
        $VERBOSE && echo "  Instance ID:      $instanceid"
        name= created=
        eval $($TIMEOUT openstack server show $instanceid \
            -c name -c created -f shell)
        test -z "$name" -o -z "$created" && continue
        $VERBOSE && echo "  Instance Name:    $name"
        $VERBOSE && echo "  Instance Created: $created"
        # only instnaces named juju-*
        if ! echo "$name" | grep -q '^juju'; then
            $VERBOSE && echo "    Skipping non-juju instance"
        else
            age=$(( NOW - $(date +%s --date "$created") ))
            if (( age < (HOURS*3600) )); then
                $VERBOSE && echo "    Instance younger than $HOURS hours"
            else
                $VERBOSE && echo "    Deleting instance older than $HOURS hours"
                $TIMEOUT openstack server delete $instanceid
            fi
        fi
    done
done
