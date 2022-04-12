    
    set -eux
    
    # Install microk8s and kubectl
    sudo snap install microk8s --classic
    sudo microk8s enable dns storage
    sudo snap install kubectl --classic
	echo "waiting for microk8s storage to become available"
    NEXT_WAIT_TIME=0
    until [ $NEXT_WAIT_TIME -eq 30 ] || microk8s status --yaml | grep -q 'storage: enabled'; do
    	sleep $(( NEXT_WAIT_TIME++ ))
    done
    if [ $NEXT_WAIT_TIME == 30 ]; then
    	echo "microk8s storage is still not enabled"
        exit 1
    fi
    
    # Install docker
    sudo apt-get install -y \
      apt-transport-https \
      ca-certificates \
      curl \
      gnupg-agent \
      software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    sudo add-apt-repository \
      "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) \
      stable"
    sudo apt-get update -y
    sudo apt-get install docker-ce docker-ce-cli containerd.io -y
    sudo systemctl start docker
    
    # Capture env and start a new session to get new groups.
    SAVE_ENV="$(export -p)"
    sudo su - $USER -c "$(echo "$SAVE_ENV" && cat <<'EOS'
    (
        PRE=$(pwd)
        cd ${{WORKSPACE}}/_build/src/github.com/juju/juju
        make operator-image microk8s-operator-update
        cd "$PRE"
    )
EOS
)"
