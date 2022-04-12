#!/bin/bash
set -eux

CURRENT_HEAD_SHA="$(curl -s "https://api.github.com/repos/${{ghprbGhRepository}}/pulls/${{ghprbPullId}}" | jq -r '.head.sha')" 
if [ "${{CURRENT_HEAD_SHA}}" != "${{ghprbActualCommit}}" ]; then
    echo "PR ${{ghprbPullLink}} head has changed, retry merge."
    exit 1
fi

BODY_FILE="${{WORKSPACE}}/merge-${{ghprbPullId}}.txt"
# Long random EOM to prevent code injection due to templating used by jenkins.
cat | sudo tee ${{BODY_FILE}} <<EOM83bbd81ba02cc92bf3c97602ad9f947f2a9e87d2a631e77d59cb842df2d90a9e
{merge_comment}
EOM83bbd81ba02cc92bf3c97602ad9f947f2a9e87d2a631e77d59cb842df2d90a9e

set +x
export GITHUB_TOKEN="$(cat ${{GITHUB_TOKEN_FILE}})"
set -x

gh pr merge "${{ghprbPullLink}}" --merge --body-file "${{BODY_FILE}}"

rm "${{BODY_FILE}}"
