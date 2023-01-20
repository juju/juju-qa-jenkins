#!/bin/bash
set -ex

case $(uname -m) in

  x86_64)
    GOARCH=amd64
    ;;

  amd64)
    GOARCH=amd64
    ;;

  arm64)
    GOARCH=arm64
    ;;

  aarch64)
    GOARCH=arm64
    ;;

  *)
    echo "Bad arch $(uname -m)"
    ;;
esac

if [ -z "${GOVERSION}" ]; then
  echo "No GOVERSION defined. Skip Go installation."
  exit 0
fi

GOTAR=$(curl -s https://go.dev/dl/ | grep -oE "go${GOVERSION}(\.[0-9]+)?\.linux-${GOARCH}.tar.gz" | head -n1)

wget -q "https://golang.org/dl/${GOTAR}"
sudo tar -C /usr/local -xzf "${GOTAR}"

sudo ln -s /usr/local/go/bin/go /usr/local/bin/go
sudo ln -s /usr/local/go/bin/gofmt /usr/local/bin/gofmt

exit 0
