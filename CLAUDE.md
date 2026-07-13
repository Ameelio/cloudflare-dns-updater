# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Agent Instructions

- When using kubectl to reach staging, use --kubeconfig=/home/ben/.kube/ameelio-k8s-staging-nyc3-kubeconfig.yaml
- When using kubectl to reach prod, use --kubeconfig=/home/ben/.kube/ameelio-k8s-prod-nyc1-kubeconfig.yaml
- When environment isn't clear from or overridden by the conversation context, default to using staging instead of prod
- The CronJob lives in namespace `cloudflare-dns-updater-staging` (runs every 3 minutes) or `cloudflare-dns-updater-prod` (runs every 2 minutes)

## What this is

A single-file Ruby script (`app.rb`) that reconciles Cloudflare DNS A records with the external IPs of Kubernetes nodes. It runs as a `CronJob` inside the cluster it is updating, so it talks to *two* APIs: the in-cluster Kubernetes API (`https://kubernetes.default.svc`) and the Cloudflare API. The reconciliation is idempotent — it only writes when desired != actual.

Read calls to both APIs go through `get_json_array`, which retries transient failures in-process (3 attempts, 10 s apart, 10 s open / 20 s read HTTP timeouts — sized to fit the CronJob's `activeDeadlineSeconds: 180`): network errors, non-JSON bodies, and JSON envelopes missing the expected array (Cloudflare returns those during brief API incidents) are all retried; if the last attempt still fails, the raw response is logged and the script exits 1 without a backtrace. Cloudflare auth failures (error code 10000) exit immediately. Writes (create/delete) are *not* retried — a failed write fails the run and the next scheduled cycle reconciles. Creates run before deletes; if any create fails the run exits 1 without entering the delete phase, so a run that can't create records never deletes any.

Filter rules baked into `app.rb` (not config):
- Only nodes labelled `ameelio.org/pool=main` or `ameelio.org/pool=infra` are considered.
- Only the node's `ExternalIP` is used.
- Only Cloudflare A records whose name starts with `${HOSTNAME}` (case-insensitive) are managed; other records in the zone are left alone.

If you change any of these filters, the script may start touching records or nodes it shouldn't.

## Runtime contract

The script reads everything from env vars; there is no config file or CLI parsing.

| Var            | Source                                                           | Notes                                                                                      |
|----------------|------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
| `CF_TOKEN`     | k8s Secret `cloudflare-dns-updater-secrets`                      | Cloudflare API bearer token. `CF_AUTH_EMAIL` / `CF_AUTH_KEY` are referenced but unused.    |
| `HOSTNAME`     | ConfigMap                                                        | e.g. `cvh-staging`; A records named `${HOSTNAME}.${DOMAIN}` are what gets managed          |
| `DOMAIN`       | ConfigMap                                                        | e.g. `ameelio.xyz` (staging) / `ameelio.org` (prod)                                        |
| `ZONE_ID`      | ConfigMap                                                        | Cloudflare zone ID                                                                         |
| `DEBUG_OUTPUT` | ConfigMap                                                        | `Yes` enables `[DEBUG]` logging                                                            |
| K8s API token  | mounted at `/var/run/secrets/kubernetes.io/serviceaccount/token` | In-cluster only. The script disables TLS verification against the k8s API (`VERIFY_NONE`). |

The pod uses `ServiceAccount cloudflare-dns-updater-sa` bound to a `ClusterRole` granting `get/list/watch` on `nodes` cluster-wide.

The Secret `cloudflare-dns-updater-secrets` is not in the repo (`k8s/*/secrets.yaml` is gitignored) — it must already exist in the namespace for the pod to start. Records the script creates are `proxied: false` with `ttl: 360`.

## Building, running, deploying

The "current" pipeline uses the `*-release.sh` scripts. The `*-prod.sh`, `*-staging.sh`, and `*-version.sh` scripts in `scripts/` are older, are not exercised by CI, and reference image names (`cloudflare-updater-prod` / `cloudflare-updater-staging`) that are no longer built or pushed. Prefer the release scripts.

| Task                  | Command                                                                                  |
|-----------------------|------------------------------------------------------------------------------------------|
| Build image           | `RELEASE_VERSION=<sha> ./scripts/build-release.sh` (defaults to `git rev-parse HEAD`)    |
| Push image            | `./scripts/push-release.sh`                                                              |
| Render manifests only | `./scripts/deploy-release.sh --save-deploy --manifest-dir manifests-<ver>-<env> --debug` |
| Diff against cluster  | `./scripts/deploy-release.sh --diff-deploy --manifest-dir ...`                           |
| Apply to cluster      | `./scripts/deploy-release.sh --apply-deploy --manifest-dir ...`                          |
| "Tests" (CI)          | `./scripts/run-ci.sh` — currently a no-op (`exit 0`); there is no test suite.            |

`deploy-release.sh` is a large bash script with `--save-*`, `--diff-*`, `--apply-*` actions for both *migration* and *deploy* manifests. The migration path is dead code here (no migration manifest exists for this app) but the flags are still wired up. Required env: `ENV`, `RELEASE_VERSION`, and for apply ops `K8S_SERVER` + `K8S_TOKEN`. The script `envsubst`-renders `k8s/${ENV}/deploy.yaml` (which contains `${RELEASE_VERSION}`, `${HOSTNAME}`, `${DOMAIN}`, `${ZONE_ID}` placeholders) into the manifest dir before applying. Nothing validates that `HOSTNAME`, `DOMAIN`, or `ZONE_ID` are set — if they aren't exported, `envsubst` silently renders empty strings into the ConfigMap, so export all of them before any `--save-deploy`.

TLS to the API server is currently `--insecure-skip-tls-verify=true` (see `k8s_ca` in `deploy-release.sh`) due to a kubectl/cert bug referenced inline. The `k8s/ca-cert/*.ca.crt` files exist but aren't used.

## CI / release flow

`.github/workflows/build-test-deploy.yml` triggers on push to `master`, on `prod-*` tags, and daily at 06:00 UTC:

1. **build** — `build-release.sh` then `push-release.sh` to `registry.digitalocean.com/ameelio-registry/cloudflare-dns-updater:<sha>` (and `:latest`).
2. **test** — `run-ci.sh` (no-op).
3. **deploy-staging** — always, after build+test. `ENV=staging`, `DOMAIN=ameelio.xyz`, `HOSTNAME=cvh-staging`, hardcoded staging `ZONE_ID`.
4. **deploy-prod** — only when `github.ref` starts with `refs/tags/prod-`. `ENV=prod`, `DOMAIN=ameelio.org`, `HOSTNAME=cvh-prod`, hardcoded prod `ZONE_ID`.

Deploy jobs post Slack notifications via `deploy-release.sh` when `SLACK_TOKEN` is set (staging → `#connect-bots`, prod → `#infa-info`).

To ship to prod, push a `prod-*` tag. Master pushes only reach staging.

## Local iteration

There is no host-side Ruby workflow; everything goes through Docker. The `run-prod.sh` / `run-staging.sh` scripts pull the obsolete image names and set only `DEBUG_OUTPUT=yes` — the script also needs `CF_TOKEN`, `HOSTNAME`, `DOMAIN`, `ZONE_ID`, and an in-cluster SA token, so they're not useful outside the cluster. For quick local edits to `app.rb`, rebuild with `build-release.sh` and inspect with `docker run --rm -it --entrypoint /bin/bash <image>`.

## Conventions specific to this repo

- `app.rb` uses top-level functions (no classes/modules) and Ruby 3 endless method syntax (`def x = ...`). Match that style if extending it; don't introduce a class for one new helper.
- `app.rb` ends with `main ARGV if __FILE__ == $PROGRAM_NAME`, so a harness can `load` it and stub `http_request` / `sleep` / `k8s_token` (top-level redefinition wins) without triggering a cycle.
- No runtime gems: HTTP calls go through `net/http` (stdlib). Adding a gem means re-introducing `Gemfile` + `bundle install` in the `Dockerfile` and bringing back a build toolchain (`ruby-devel`, `gcc-c++`, `make`).
- `k8s/staging/` and `k8s/prod/` are parallel environment dirs; `deploy-release.sh` selects via `ENV`. Keep those two structurally in sync. `k8s/dev/` is stale (`batch/v1beta1`, hardcoded values instead of `envsubst` placeholders, no RBAC) and is never deployed by CI — don't use it as a template.
- The ServiceAccount/RBAC objects are duplicated in each env's `deploy.yaml` and `service-account.yaml`; the release pipeline only renders and applies `deploy.yaml`, so RBAC changes must land there (keep the duplicate in sync).
- `TODO.md` is a human-only scratchpad — do not read or edit it.

# context-mode — MANDATORY routing rules

You have context-mode MCP tools available. These rules are NOT optional — they protect your context window from flooding. A single unrouted command can dump 56 KB into context and waste the entire session.

## BLOCKED commands — do NOT attempt these

### curl / wget — BLOCKED
Any Bash command containing `curl` or `wget` is intercepted and replaced with an error message. Do NOT retry.
Instead use:
- `ctx_fetch_and_index(url, source)` to fetch and index web pages
- `ctx_execute(language: "javascript", code: "const r = await fetch(...)")` to run HTTP calls in sandbox

### Inline HTTP — BLOCKED
Any Bash command containing `fetch('http`, `requests.get(`, `requests.post(`, `http.get(`, or `http.request(` is intercepted and replaced with an error message. Do NOT retry with Bash.
Instead use:
- `ctx_execute(language, code)` to run HTTP calls in sandbox — only stdout enters context

### WebFetch — BLOCKED
WebFetch calls are denied entirely. The URL is extracted and you are told to use `ctx_fetch_and_index` instead.
Instead use:
- `ctx_fetch_and_index(url, source)` then `ctx_search(queries)` to query the indexed content

## REDIRECTED tools — use sandbox equivalents

### Bash (>20 lines output)
Bash is ONLY for: `git`, `mkdir`, `rm`, `mv`, `cd`, `ls`, `npm install`, `pip install`, and other short-output commands.
For everything else, use:
- `ctx_batch_execute(commands, queries)` — run multiple commands + search in ONE call
- `ctx_execute(language: "shell", code: "...")` — run in sandbox, only stdout enters context

### Read (for analysis)
If you are reading a file to **Edit** it → Read is correct (Edit needs content in context).
If you are reading to **analyze, explore, or summarize** → use `ctx_execute_file(path, language, code)` instead. Only your printed summary enters context. The raw file content stays in the sandbox.

### Grep (large results)
Grep results can flood context. Use `ctx_execute(language: "shell", code: "grep ...")` to run searches in sandbox. Only your printed summary enters context.

## Tool selection hierarchy

1. **GATHER**: `ctx_batch_execute(commands, queries)` — Primary tool. Runs all commands, auto-indexes output, returns search results. ONE call replaces 30+ individual calls.
2. **FOLLOW-UP**: `ctx_search(queries: ["q1", "q2", ...])` — Query indexed content. Pass ALL questions as array in ONE call.
3. **PROCESSING**: `ctx_execute(language, code)` | `ctx_execute_file(path, language, code)` — Sandbox execution. Only stdout enters context.
4. **WEB**: `ctx_fetch_and_index(url, source)` then `ctx_search(queries)` — Fetch, chunk, index, query. Raw HTML never enters context.
5. **INDEX**: `ctx_index(content, source)` — Store content in FTS5 knowledge base for later search.

## Subagent routing

When spawning subagents (Agent/Task tool), the routing block is automatically injected into their prompt. Bash-type subagents are upgraded to general-purpose so they have access to MCP tools. You do NOT need to manually instruct subagents about context-mode.

## Output constraints

- Keep responses under 500 words.
- Write artifacts (code, configs, PRDs) to FILES — never return them as inline text. Return only: file path + 1-line description.
- When indexing content, use descriptive source labels so others can `ctx_search(source: "label")` later.

## ctx commands

| Command | Action |
|---------|--------|
| `ctx stats` | Call the `ctx_stats` MCP tool and display the full output verbatim |
| `ctx doctor` | Call the `ctx_doctor` MCP tool, run the returned shell command, display as checklist |
| `ctx upgrade` | Call the `ctx_upgrade` MCP tool, run the returned shell command, display as checklist |
