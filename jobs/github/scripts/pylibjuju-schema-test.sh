    #!/bin/bash
    set -ex

    if [ -z "$target_branch" ]; then
        echo "No \$target_branch set, unable to continue."
        exit 1
    fi


    sudo add-apt-repository ppa:deadsnakes/ppa
    sudo apt-get update -q
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git gcc make python3.5 python3.6 python3.7 python3.8 python3-pip

    # now go to libjuju and make sure it's working correctly
    mkdir -p ~/tmp
    git clone git://github.com/juju/python-libjuju.git ~/tmp/python-libjuju

    cd ~/tmp/python-libjuju

    git checkout $target_branch
    pip3 install --user tox || true
    export PATH="$HOME/.local/bin:$PATH"

    # test that we installed it correctly.
    tox -e lint --notest

    libjuju_path="$HOME/tmp/python-libjuju"
    juju_home="${GOPATH}/src/github.com/juju/juju"
    facades_schema_path="apiserver/facades/schema.json"
    libjuju_schema_path="juju/client/schemas-juju-latest.json"

    if [ ! -f "$juju_home/$facades_schema_path" ]; then
        echo "schema.json not found in juju"
        exit 1
    fi

    rm "$libjuju_path/$libjuju_schema_path"
    cp "$juju_home/$facades_schema_path" "$libjuju_path/$libjuju_schema_path"

    # now test that make client works correctly
    make client
    output=$(git status --porcelain)
    if [ -z $output ]; then
        check_exit=0
    else
        echo "There are changes to the pylibjuju schema"
        echo "You need to update pylibjuju because you've updated the client"
        echo "See: https://discourse.jujucharms.com/t/python-libjuju/1553"
        check_exit=1
    fi
