#!/bin/sh

case $(lsb_release -c -s) in

  noble)
    wget https://repo.mongodb.org/apt/ubuntu/dists/focal/mongodb-org/4.4/multiverse/binary-amd64/mongodb-org-server_4.4.15_amd64.deb
    wget https://repo.mongodb.org/apt/ubuntu/dists/focal/mongodb-org/4.4/multiverse/binary-amd64/mongodb-org-mongos_4.4.15_amd64.deb
    wget https://repo.mongodb.org/apt/ubuntu/dists/focal/mongodb-org/4.4/multiverse/binary-amd64/mongodb-org-shell_4.4.15_amd64.deb
    sudo dpkg -i *.deb
    ;;

  jammy)
    wget http://security.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2.16_amd64.deb
    wget https://repo.mongodb.org/apt/ubuntu/dists/focal/mongodb-org/4.4/multiverse/binary-amd64/mongodb-org-server_4.4.15_amd64.deb
    wget https://repo.mongodb.org/apt/ubuntu/dists/focal/mongodb-org/4.4/multiverse/binary-amd64/mongodb-org-mongos_4.4.15_amd64.deb
    wget https://repo.mongodb.org/apt/ubuntu/dists/focal/mongodb-org/4.4/multiverse/binary-amd64/mongodb-org-shell_4.4.15_amd64.deb
    sudo dpkg -i *.deb
    ;;

  focal)
    wget https://repo.mongodb.org/apt/ubuntu/dists/focal/mongodb-org/4.4/multiverse/binary-amd64/mongodb-org-server_4.4.15_amd64.deb
    wget https://repo.mongodb.org/apt/ubuntu/dists/focal/mongodb-org/4.4/multiverse/binary-amd64/mongodb-org-mongos_4.4.15_amd64.deb
    wget https://repo.mongodb.org/apt/ubuntu/dists/focal/mongodb-org/4.4/multiverse/binary-amd64/mongodb-org-shell_4.4.15_amd64.deb
    sudo dpkg -i *.deb
    ;;

  *)
    echo "Bad series $(lsb_release -c -s)"
    exit 1
    ;;

esac

mongo --version
mongod --version
mongos --version
