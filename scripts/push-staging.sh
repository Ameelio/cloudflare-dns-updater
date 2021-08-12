#!/usr/bin/env bash

docker push --authfile ~/.docker/do-config.json registry.digitalocean.com/ameelio-registry/cloudflare-updater-staging:latest
docker push --authfile ~/.docker/do-config.json registry.digitalocean.com/ameelio-registry/cloudflare-updater-staging:v1.0.0
