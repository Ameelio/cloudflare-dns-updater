#!/usr/bin/env bash

if [ -z "${RELEASE_VERSION}" ]; then
  RELEASE_VERSION="$(git rev-parse HEAD)"
fi

docker push "registry.digitalocean.com/ameelio-registry/cloudflare-dns-updater:latest"
docker push "registry.digitalocean.com/ameelio-registry/cloudflare-dns-updater:${RELEASE_VERSION}"

