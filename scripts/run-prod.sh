#!/usr/bin/env bash

docker run --rm \
  --env 'DEBUG_OUTPUT=yes' \
  registry.digitalocean.com/ameelio-registry/cloudflare-updater-prod:latest
