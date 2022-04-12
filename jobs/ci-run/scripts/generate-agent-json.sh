#!/bin/bash
set -e

# Used to generate agent metadata for CI tests

output_file_name="{output_dir}/build-${{SHORT_GIT_COMMIT}}-{product_name}-${{BUILD_ARCH}}.json"

# constants
# Need location passed in. . .
agent_file_name="juju-${{JUJU_VERSION}}-{product_name}-${{BUILD_ARCH}}.tgz"
source_agent_file="{agent_file_source_dir}/${{agent_file_name}}"
echo "Generating for ${{JUJU_VERSION}} using ${{agent_file}}"

arch=${{BUILD_ARCH}}
content_id_part=build-${{SHORT_GIT_COMMIT}}
# Note: gui needs sha1 too.
md5=$(md5sum ${{source_agent_file}} | awk '{{print $1}}')
sha256=$(sha256sum ${{source_agent_file}} | awk '{{print $1}}')
file_size=$(du -b ${{source_agent_file}} | awk '{{print $1}}')
# determine what the file path will be
agent_path=agent/build-${{SHORT_GIT_COMMIT}}/${{agent_file_name}}
# This seems redundant
version=${{JUJU_VERSION}}
version_name=$(date +"%Y%m%d")

agent_loop=({product_name})
index_type="agents"
if [[ "${{version}}" == 2.8* ]]; then
  agent_loop=({product_series})
  index_type="tools"
fi


echo "[" > $output_file_name
for agent_type in ${{agent_loop[@]}}; do
    final_comma=","
    if [[ $agent_type == ${{agent_loop[-1]}} ]]; then
        final_comma=""
    fi

    # Legacy Ubuntu metadata needs a series-name and series-code,
    # if there is no ':' separator defaults to the same as release_name
    release_name=$(echo $agent_type | cut -d: -f1)
    series_code=$(echo $agent_type | cut -d: -f2)

    item_name=${{version}}-${{agent_type}}-${{arch}}
    cat >> $output_file_name <<EOF
    {{
        "arch": "${{arch}}",
        "content_id": "com.ubuntu.juju:${{content_id_part}}:${{index_type}}",
        "format": "products:1.0",
        "ftype": "tar.gz",
        "item_name": "${{item_name}}",
        "md5": "${{md5}}",
        "path": "${{agent_path}}",
        "product_name": "com.ubuntu.juju:${{series_code}}:${{arch}}",
        "release": "${{release_name}}",
        "sha256": "${{sha256}}",
        "size": ${{file_size}},
        "version": "${{version}}",
        "version_name": "${{version_name}}"
    }}$final_comma
EOF
done
echo "]" >> $output_file_name
