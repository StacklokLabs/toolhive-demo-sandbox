---
name: validate-manifests
description: Server-side dry-run validate Kubernetes manifests in the toolhive-demo-sandbox repo against the live kind cluster's CRDs. Use before committing changes to demo-manifests/, addons/, or infra/, after bumping the ToolHive operator version, or whenever schema drift is suspected — catches issues like removed inline fields (telemetry, oidcConfig, config.groupRef), required-field additions, and webhook rejections that client-side validation misses. Requires a running demo cluster.
---

# validate-manifests

Runs each candidate YAML through `envsubst` (with known-safe placeholder values for every `$VAR` used in manifests) and pipes it to `kubectl apply --dry-run=server -f -`, producing a per-file PASS/FAIL/SKIP summary. Server-side dry-run validates against the live CRDs and admission webhooks — it catches operator-version schema drift that client-side validation silently accepts.

## When to run

- Before `git commit` after editing anything under `demo-manifests/`, `addons/`, or `infra/`
- After bumping `TOOLHIVE_OPERATOR_*` versions in `bootstrap.sh` (new CRDs, removed fields)
- When diagnosing apply-time failures in the live cluster
- As a sanity check after renovate-style dependency bumps land

## Usage

Run from anywhere in the repo — the script resolves the repo root from git.

```sh
# Default: only YAMLs changed vs HEAD (staged, unstaged, untracked) in scoped dirs
.claude/skills/validate-manifests/scripts/validate.sh

# Every YAML under demo-manifests/, addons/, infra/
.claude/skills/validate-manifests/scripts/validate.sh --all

# Specific files
.claude/skills/validate-manifests/scripts/validate.sh demo-manifests/vmcp-infra.yaml addons/vmcp-infra-okta/vmcp.yaml
```

Exit code is non-zero if any file fails. Output lines are prefixed with `PASS`, `FAIL`, or `SKIP`; failures include the first few lines of the server error.

## Prerequisites

- Demo cluster running (the script aborts with a clear message if `kubectl cluster-info` fails)
- `envsubst` and `kubectl` on PATH
- Script sets `KUBECONFIG=$REPO_ROOT/kubeconfig-toolhive-demo.yaml` automatically if that file exists

## What it skips

- `*-helm-values.yaml` / `values.yaml` — Helm values are not K8s manifests (no `apiVersion`/`kind`)
- `patch.yaml` / `*-patch.yaml` — strategic-merge patches applied via `kubectl patch`, not complete resources

## Extending

New `$VAR` placeholders in manifests need a corresponding `export` in [scripts/validate.sh](scripts/validate.sh). To enumerate the current placeholder set:

```sh
find demo-manifests addons infra \( -name '*.yaml' -o -name '*.yml' \) \
    -exec grep -hoE '\$\{?[A-Z_][A-Z0-9_]*\}?' {} \; | sed 's/[${}]//g' | sort -u
```

Add any missing names to the placeholder block at the top of the script. Values only need to satisfy CRD schema regexes (e.g. `^https?://`), not reach anything real.
