#!/usr/bin/env bash

if [ -n "${$ENV}" ]; then
  echo "Current env (\$ENV) is '${ENV}'"
else
  echo "Env var \$ENV is not set. Please set and try again"
  exit 1
fi

echo "-- Pre-deploy diff --"
cat k8s/${ENV}/* \
  | envsubst \
  | kubectl diff -f -

echo "-- Applying changes --"
cat k8s/${ENV}/*.yaml \
  | envsubst \
  | kubectl apply -f -
