#!/usr/bin/env bash

docker push --authfile ~/.docker/do-config.json registry.digitalocean.com/ameelio-registry/cloudflare-updater-prod:latest
docker push --authfile ~/.docker/do-config.json registry.digitalocean.com/ameelio-registry/cloudflare-updater-prod:v1.0.0
