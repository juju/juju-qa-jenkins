#!/bin/bash
set -eu

export TZ=UTC
HOURS=4
NOW=$(date +%s)
REGIONS=(
    us-west-2
    us-east-1
    us-east-2
    ca-central-1
    eu-west-1
    eu-west-2
    eu-west-3
    eu-north-1
    eu-central-1
    ap-northeast-1
    ap-northeast-2
    ap-southeast-1
    ap-southeast-2
    ap-south-1
    ap-east-1
    me-south-1
    sa-east-1
    # not accessible regions for QA account.
    # us-west-1
    # cn-northwest-1
    # cn-north-1
)

export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_KEY}

for region in ${REGIONS[@]}; do
    echo "Finding deletable eks clusters in $region"
    # Get EKS which were created more than 3 hours ago.
    for name in $(eksctl get cluster -o json --region $region | jq -r '.[].name'); do
        # eksctl gives very limited information in list command, so we have to list then get to gather sufficient information we need.
        for cluster in $(
            eksctl get cluster --name $name --region $region -o json | 
            jq "select( $NOW - (.[].CreatedAt | strptime(\"%Y-%m-%dT%H:%M:%S%Z\") | mktime ) > ($HOURS * 3600)  )" | 
            jq -r '.[].Name'
        ); do
            echo "  - deleting cluster -> $cluster"
            eksctl delete cluster $cluster --region $region
        done
    done
done
