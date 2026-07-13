#!/bin/bash
set -euo pipefail

export TZ=UTC
HOURS=4
NOW=$(date +%s)
REGIONS=(
    us-west-2
    us-east-1
)

set +x
export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_KEY}

AWS_CLI_VER=$(aws --version | cut -d " " -f 1 | cut -d / -f 2 | cut -d . -f 1)
CREATED_AT_SELECTOR=".createdAt"
if [ $AWS_CLI_VER -ge 2 ]; then
CREATED_AT_SELECTOR="(.createdAt | strptime(\"%Y-%m-%dT%H:%M:%S%Z\") | mktime )"
fi

for region in ${REGIONS[@]}; do
    echo "=> checking ECR registries in $region..."
    for name in $(
        aws ecr-public describe-repositories --region ${region} |
        jq ".repositories[] | select( ${NOW} - ${CREATED_AT_SELECTOR} > (${HOURS} * 3600)  )" |
        jq -r .repositoryName
    ); do
        aws ecr-public delete-repository --repository-name "${name}" --region ${region} --force
        echo "  - ${name} DELETED!"
    done
done
