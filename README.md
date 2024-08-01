# Cloudflare DNS Updater

## About this project

### What

This is a script that keeps a set of DNA A records on Cloudflare continually updated to point to the Kubernetes nodes in the cluster.

### Why

With most managed Kubernetes providers, IP addresses of nodes can change quickly.  This is especially common when applying security updates to the nodes.  The nodes are immutable, so are actually recycled/replaced rather than upgraded.  When this happens the new nodes receive a new IP address, which needs to be reflected in DNS.  

### How

This script is invoked by a Kubernetes Cron Job periodically.  It will enumerate the current nodes and their IP addresses, and compare that list to the DNS A records in Cloudflare.  If there is a discrepancy, it will be resolved by updating the DNS A records so that there is one A record per node.  The script is idempotent, so is safe to run many times.  It will only make changes if the desired state is different than the current state.

## Usage

Apply the Kubernetes manifests from `k8s` directory to a cluster.  This will create the CronJob and associated RBAC objects so the script has permission to enumerate the nodes in the cluster through the Kubernetes API.

A Github workflow is set up currently to automatically build and deploy on each commit to the master branch.

