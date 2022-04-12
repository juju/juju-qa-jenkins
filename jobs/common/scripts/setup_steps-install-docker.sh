#!/bin/bash

# Get docker installed and setup.
# From the official Docker docs https://docs.docker.com/engine/install/ubuntu/
set -eux

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gnupg \
  lsb-release

# Add Dockers gpg keys
echo "Adding Docker gpg keys"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Setup stable repository
echo "Setting up Docker stable repository"
echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
echo "Installing docker"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io
echo "Making sure docker is enabled"
sudo systemctl start docker
echo "Adding $USER to the docker group"
sudo usermod -aG docker $USER

# Enabled experimental docker features, must be before login.
# Also add http proxy if we have one
echo "Making docker config with experimental features and configuring http proxies"

mkdir -p "${HOME}/.docker"
if [ ! -z "${http_proxy:-}" ]; then
cat << EOC > ${HOME}/.docker/config.json
{
    "experimental": "enabled",
    "proxies": {
        "default": {
            "httpProxy": "${http_proxy}",
            "httpsProxy": "${http_proxy}"
        }
    }
}
EOC
else
cat << EOC > ${HOME}/.docker/config.json
{
    "experimental": "enabled"
}
EOC
fi

echo "Installing support for other binfmt to aid on cross compiling docker images"
sudo docker run --privileged --rm tonistiigi/binfmt --install all
