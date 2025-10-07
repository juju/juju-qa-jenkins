#!/bin/bash
set -eu

# Display instances' regions
python3 $SCRIPTS_DIR/gce.py -v list-instances juju-*

python3 $SCRIPTS_DIR/gce.py -v delete-instances -o 2 juju-*

gcloud auth activate-service-account --key-file=$GCE_CREDENTIALS_FILE
gcloud config set project gothic-list-89514
gcloud compute firewall-rules list

# TODO - we no longer store state between jobs invocations.
# We need a new way to delete stale filewall rules.
touch ~/gcerules

# On every job run, remove any rules that still exist from last run
# generate gce rules with
# gcloud compute firewall-rules list | awk {'print $1'} | grep juju > ~/gcerules
gcloud compute firewall-rules list | awk {'print $1'} | grep juju | sort -u > newrules
# destroy all rules still found
comm -1 -2  ~/gcerules newrules | xargs  -I % gcloud compute firewall-rules delete % --quiet
# set new rules
mv newrules ~/gcerules
