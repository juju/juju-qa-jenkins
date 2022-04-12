#!/bin/bash
set -eux

if [ which timedatectl >/dev/null 2>&1 ]; then
    echo "Using timedatectl."
    sudo timedatectl set-ntp on
    exit 0
fi

if ! [ which ntpq >/dev/null 2>&1 ]; then
    echo "Attempting to install ntp."
    sudo DEBIAN_FRONTEND=noninteractive apt-get -f install -y ntp
fi

echo "Query NTP Peers for information."
sudo ntpq -p
sudo systemctl restart ntp
sudo systemctl enable ntp
