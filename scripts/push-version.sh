#!/usr/bin/env bash

LATEST_VERSION='20210922001'

docker push "registry.digitalocean.com/ameelio-registry/cloudflare-dns-updater:latest"
docker push "registry.digitalocean.com/ameelio-registry/cloudflare-dns-updater:${LATEST_VERSION}"
