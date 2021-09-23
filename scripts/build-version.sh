#!/usr/bin/env bash

LATEST_VERSION='20210922001'

docker build \
  -t "registry.digitalocean.com/ameelio-registry/cloudflare-dns-updater:${LATEST_VERSION}" \
  -t "registry.digitalocean.com/ameelio-registry/cloudflare-dns-updater:latest" \
  .
