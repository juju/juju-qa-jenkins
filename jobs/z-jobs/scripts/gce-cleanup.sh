#!/bin/bash
set -eu

# Display instances' regions
python3 $SCRIPTS_DIR/gce.py -v list-instances juju-*

python3 $SCRIPTS_DIR/gce.py -v delete-instances -o 2 juju-*

python3 $SCRIPTS_DIR/gce.py -v delete-security-groups juju-
