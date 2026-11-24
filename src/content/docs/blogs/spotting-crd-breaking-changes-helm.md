---
title: Spot Breaking CRD Changes Before Your Helm Chart Bump Hits the Cluster
description: How to catch incompatible CustomResourceDefinition changes when bumping Helm charts with Argo CD, using crdify, Pluto, and kubeconform, with External Secrets Operator as the worked example.
sidebar:
  order: 6
---
*By Shankar Ramanathan*

Helm installs CRDs on initial install and ignores them on subsequent chart bumps. Argo CD diffs highlight Deployments and ConfigMaps, while changes to the CRD schemas in `crds/` slip past unnoticed.

That is how cluster outages happen. When you bump External Secrets from `v0.15.x` to `v0.16.x` and then `v0.17.0`, the PR turns green because the controller image changed and `helm template` still renders.

What the diff does not show is that `v0.16.0` removes conversion webhooks and stops serving `v1alpha1` on core kinds (`ExternalSecret`, `SecretStore`, `ClusterSecretStore`, `ClusterExternalSecret`). One minor bump later, `v0.17.0` stops serving `v1beta1`. Manifests left on `external-secrets.io/v1alpha1` or `v1beta1` fail admission or stop reconciling, secret sync stalls, and someone files a ticket against Kubernetes when the failure was an unexamined CRD delta.

If you vend operator charts through GitOps, compare extracted CRD YAML on **each minor hop** before merge (not only the final pin), run crdify, Pluto, and kubeconform in CI, and fail the PR when schema, apiVersion, or fixtures regress. The worked example is ESO `v0.15.x` through `v0.17.0`; the executable checklist is [`SKILL.md`](/skills/crd-helm-version-guardrails/SKILL.md).

---

## What is a breaking CRD change?

A CustomResourceDefinition change is breaking when existing custom resources (CRs) stop validating, stop converting, or stop being served after the new CRD is applied.

Common break classes:

| Change | Why it breaks existing CRs |
|---|---|
| Field removed from OpenAPI schema | Objects that still set the field fail validation on update |
| Field type changed | Stored values no longer match the schema |
| New field added to `required` | Existing objects missing the field become invalid |
| Enum tightened or newly constrained | Previously valid values are rejected |
| Served API version removed | Clients and manifests on that `apiVersion` get discovery / admission failures |
| Conversion strategy / webhook changed incorrectly | Reads and writes fail mid-upgrade (SSA and managedFields make this worse) |
| `x-kubernetes-list-type` / merge key changes | Server-side apply ownership and merges behave differently |

Additive *optional* fields are usually non-breaking. Description-only edits are noise. Served-version removal is always a hard break for anyone still on the old `apiVersion`, even if the `v1` schema looks fine.

Helm's own docs are blunt: CRDs in `crds/` are installed once and skipped if present. There is no supported Helm path to upgrade or delete CRDs. Operators who treat a chart version bump as "the CRDs will follow" are wrong. See Helm's [chart best practices for CRDs](https://helm.sh/docs/chart_best_practices/custom_resource_definitions/).

---

## Why one linter cannot catch Helm CRD bumps (crdify, Pluto, kubeconform)

One tool does not cover the full failure mode. Use three layers that all run the same way locally and on GitHub Actions runners.

```
  ┌─────────────────────────────────────────────────────────────┐
  │  Chart pin bump: external-secrets 0.15.2 → 0.16.0 → 0.17.0 │
  └────────────────────────────┬────────────────────────────────┘
                               │
                               ▼
  ┌─────────────────────────────────────────────────────────────┐
  │  1. crdify: CRD schema / structural compatibility            │
  │     old CRD YAML  vs  new CRD YAML                          │
  └────────────────────────────┬────────────────────────────────┘
                               │
                               ▼
  ┌─────────────────────────────────────────────────────────────┐
  │  2. Pluto: consumer apiVersion deprecated / removed          │
  │     fixture manifests (ExternalSecret, SecretStore, …)      │
  └────────────────────────────┬────────────────────────────────┘
                               │
                               ▼
  ┌─────────────────────────────────────────────────────────────┐
  │  3. kubeconform: fixture instances vs *new* CRD OpenAPI      │
  └─────────────────────────────────────────────────────────────┘
```

**crdify** ([kubernetes-sigs/crdify](https://github.com/kubernetes-sigs/crdify)) compares two CRD documents and flags incompatible schema and structural changes (field removal, type change, new required fields, enum changes, SSA-related structural checks). Sources include `file://`, `git://`, and `kube://`, so the same binary works on a laptop and in CI.

**Pluto** catches deprecated or removed *apiVersions* in manifests. That is the layer that catches ESO stopping to serve `v1beta1` even when the `v1` schema compare looks clean.

**kubeconform** validates your fixture CRs against schemas derived from the *new* CRDs. apiVersion can be correct while a field shape still fails.

They fail for different reasons:

- crdify pass + Pluto fail → served version gone; migrate manifests.
- Pluto pass + kubeconform fail → apiVersion ok; field/schema drift in fixtures.
- crdify fail → do not apply CRDs until you understand the schema delta and update consumers.

`crdiff` is a reasonable directory-wide alternative to looping crdify, but it is OpenAPI-diff based and can miss some `x-kubernetes-*` semantics. Prefer crdify as the primary schema gate; mention crdiff as a complement if you need recursive directory summaries.

---

## External Secrets shipped two CRD breaks GitOps diffs will not show you

Upstream landed **two** hard breaks in back-to-back minors: conversion and `v1alpha1` removal at `v0.16.0`, then `v1beta1` unserved at `v0.17.0`. A single `targetRevision` bump can skip both stories.

### On `v0.15.x`, core kinds still served `v1alpha1` through conversion webhooks

On `v0.15.x` (and earlier), core kinds could still be stored and served as `external-secrets.io/v1alpha1`. The operator relied on **conversion webhooks** in the bundled CRDs so older objects remained readable while teams moved toward `v1beta1` and `v1`. The historical [Upgrading to v1beta1](https://external-secrets.io/v0.5.6/guides-v1beta1/) guide documents that conversion-backed transition. That path is not the same as the **`v0.16.0` hard cut** that removes webhooks entirely. Helm installs with `installCRDs=true` were the low-risk case on `0.15.x`; manual CRD applies had to follow the bundled `bundle.yaml` ordering.

If your manifests or etcd still had `v1alpha1` on `ExternalSecret` / `SecretStore` / cluster-scoped equivalents, `v0.15.x` could mask the debt. A green Helm or Argo CD diff did not prove you were ready for the next minor.

### Hop 1: `v0.16.0` removes core `v1alpha1` and conversion webhooks

[v0.16.0](https://github.com/external-secrets/external-secrets/releases/tag/v0.16.0) is the break most teams miss when they jump straight from `v0.15.x`:

- Removes conversion webhooks from the core CRDs.
- Stops serving `SecretStore/v1alpha1`, `ExternalSecret/v1alpha1`, and cluster-scoped counterparts.
- Promotes `ExternalSecret/v1`, `SecretStore/v1`, and cluster-scoped `v1` APIs.
- Drops the legacy `v1` templating engine and other breaking changes called out in the release guide (storedVersions on `v1alpha1` must be cleared before upgrade).

Upstream documents pre-flight checks (`kubectl get crd … storedVersions`, inventory for any remaining `v1alpha1` manifests). None of that shows up in a typical Application `targetRevision` bump. **crdify** on `externalsecrets.external-secrets.io` (and sibling core CRDs) *does*: you see `spec.conversion` disappear and served-version lists change between chart `0.15.x` and `0.16.x` tarballs.

In **`v0.16.x`**, newer or secondary CRDs did **not** all move to `v1` at once. Types such as `PushSecret`, `ClusterPushSecret`, `OperatorConfig`, and several secret **generators** often remained on `v1alpha1` while core store/sync types were on `v1` / dual-served `v1beta1`. A Pluto scan that only checks `ExternalSecret` misses push-path and generator CRs that still declare alpha.

Prefer **`v0.16.1+`** over `v0.16.0` when mirroring upstream’s own upgrade notes (conversion / SSA issues on the first `0.16.0` drop).

### Hop 2: bridge at `v0.16.2`, then `v0.17.0` unserves `v1beta1`

| Window | What operators must care about |
|---|---|
| `v0.15.x` | Core `v1alpha1` still convertible via webhooks; debt easy to ignore |
| `v0.16.0`+ | **Breaking:** no `v1alpha1` on core kinds; conversion webhooks removed from those CRDs |
| `v0.16.2` | Dual-serves `v1beta1` and `v1` on core kinds. Use this bridge before `v0.17.0` |
| `v0.17.0` | **Breaking:** stops serving `v1beta1` entirely (deprecated and unserved in a single minor step from the `v0.16.2` bridge) |

Upstream [v0.17.0](https://github.com/external-secrets/external-secrets/releases/tag/v0.17.0) release notes: migrate every manifest from `external-secrets.io/v1beta1` to `external-secrets.io/v1` *before* upgrading from `v0.16.x` to `v0.17.0` (usually a string change on `apiVersion`). That is a second hard gate on top of the `v0.16.0` alpha removal. Teams still on `v1beta1` after only comparing Deployment templates will fail at `0.17.0` even if they never used `v1alpha1`.

Track **PushSecret** / **ClusterPushSecret** (and generator kinds) in fixtures separately: their apiVersion may still be alpha while core kinds are on `v1`. See [`manifests/eso/pushsecret.yaml`](/manifests/eso/pushsecret.yaml) in this repo.

Always read the [release notes](https://github.com/external-secrets/external-secrets/releases?page=9) for the exact chart pin you are landing on, not only the controller tag in the parent Application.

API reference for the stable shape of ExternalSecret lives in versioned docs under [external-secrets.io](https://external-secrets.io/) (for example the [ExternalSecret API](https://external-secrets.io/latest/api/externalsecret/) page). Match doc version to the chart pin you are landing.

### Why Helm + Argo CD makes this worse

Four failure patterns show up repeatedly with ESO upgrades:

1. **Skipping `0.15.x` → `0.16.x` CRD review.** Argo CD updates the Helm release; CRDs in `crds/` may not upgrade in place (Helm install-once semantics). Even when new CRDs apply, no Deployment diff flagged removal of `v1alpha1` or conversion webhooks. Manifests and `storedVersions` still on alpha break on first reconcile after `v0.16.0`.
2. **Chart bump without manifest migration.** Controller and CRDs move to a world that no longer serves `v1beta1` (`v0.17.0`). Workloads still declare `apiVersion: external-secrets.io/v1beta1`.
3. **CRD apply with leftover conversion fields.** Server-side apply and GitOps tools do not always clear `spec.conversion` the way a full object replace would. Dry-run then fails with conversion strategy / webhookClientConfig conflicts, as upstream `v0.16.0` troubleshooting describes. Learnk8s' [server-side apply guide](https://learnkube.com/server-side-apply-kubernetes) explains why managedFields ownership matters when patching CRDs.
4. **Rollback fantasy.** After objects are stored at a newer storage version, downgrading the operator does not magically re-serve the old version for free. Migrate forward on purpose.

### Safe upgrade order for ESO

1. Inventory live and Git-managed CRs for `v1alpha1` and `v1beta1` on **core** kinds; separately inventory alpha generator / push kinds.
2. On `v0.15.x`, confirm `storedVersions` on core CRDs do not still list `v1alpha1` (upstream `v0.16.0` pre-flight).
3. Extract and **crdify** chart `0.15.x` vs `0.16.x` CRDs; read [v0.16.0](https://github.com/external-secrets/external-secrets/releases/tag/v0.16.0) release notes; apply CRDs deliberately; bump controller to `v0.16.1+` when manifests are on `v1` / dual-served `v1beta1`.
4. Land on **chart/app `v0.16.2`** (documented dual-serve of `v1beta1` and `v1`).
5. Rewrite all fixtures and Git manifests to `external-secrets.io/v1` for core kinds.
6. Confirm Pluto and cluster inventory show no removed apiVersions you still need.
7. Only then bump to **`v0.17.0+`** and apply CRD changes deliberately (not only as a side effect of `helm upgrade` / Argo CD sync).

---

## Run crdify, Pluto, and kubeconform on every operator chart bump

Run this when Dependabot, Renovate, or a human bumps an operator chart that ships CRDs.

### 1. Record the pin delta

In the PR description:

```text
chart: external-secrets/external-secrets
old: 0.15.X
new: 0.17.0
crd impact: ExternalSecret, SecretStore, ClusterSecretStore, PushSecret, …
```

If the jump spans multiple minors, list the intermediate bridge version you will actually roll through.

### 2. Extract old and new CRD YAMLs

```bash
#!/usr/bin/env bash
set -euo pipefail

CHART_REPO="${CHART_REPO:-https://charts.external-secrets.io}"
CHART_NAME="${CHART_NAME:-external-secrets}"
OLD_VER="${OLD_VER:-0.15.X}"
NEW_VER="${NEW_VER:-0.17.0}"
WORKDIR="${WORKDIR:-/tmp/crd-diff}"

rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/old" "${WORKDIR}/new"

helm repo add external-secrets "${CHART_REPO}" >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null

helm pull "external-secrets/${CHART_NAME}" --version "${OLD_VER}" --untar --untardir "${WORKDIR}/old"
helm pull "external-secrets/${CHART_NAME}" --version "${NEW_VER}" --untar --untardir "${WORKDIR}/new"

# Chart layout varies: crds/ at chart root is common for ESO.
ls "${WORKDIR}/old/${CHART_NAME}/crds" "${WORKDIR}/new/${CHART_NAME}/crds"
```

If the chart keeps CRDs elsewhere (for example a subchart or `templates/` with a CRD install job), point the next steps at that path. Do not assume `crds/` always exists.

### 3. Schema gate with crdify

Install once:

```bash
go install sigs.k8s.io/crdify@latest
```

Compare each CRD pair. crdify compares one pair per invocation:

```bash
OLD_CRDS="${WORKDIR}/old/${CHART_NAME}/crds"
NEW_CRDS="${WORKDIR}/new/${CHART_NAME}/crds"
failed=0

for new_file in "${NEW_CRDS}"/*.yaml; do
  name="$(basename "${new_file}")"
  old_file="${OLD_CRDS}/${name}"
  if [[ ! -f "${old_file}" ]]; then
    echo "NEW CRD (no old peer): ${name}"
    continue
  fi
  echo "=== crdify ${name} ==="
  if ! crdify "file://${old_file}" "file://${new_file}" -o plaintext; then
    failed=1
  fi
done

exit "${failed}"
```

Interpret failures as "schema incompatibility detected," not as "automatically unsafe forever." Some projects use an allowlist config for intentional breaks. Intentional breaks still require the Pluto and fixture steps below, plus a written migration plan.

Optional cluster compare before apply:

```bash
crdify kube://externalsecrets.external-secrets.io "file://${NEW_CRDS}/externalsecrets.external-secrets.io.yaml"
```

### 4. apiVersion gate with Pluto on fixtures

Keep a small fixture set under version control ([`src/content/manifests/eso/`](/manifests/eso/externalsecret.yaml)):

- [`externalsecret.yaml`](/manifests/eso/externalsecret.yaml)
- [`secretstore.yaml`](/manifests/eso/secretstore.yaml)
- [`clustersecretstore.yaml`](/manifests/eso/clustersecretstore.yaml)
- [`pushsecret.yaml`](/manifests/eso/pushsecret.yaml)

Run Pluto against those files (add a custom versions map for ESO if your Pluto build does not already know `external-secrets.io` removals):

```bash
pluto detect-files -d src/content/manifests/eso --output wide
```

Policy suggestion for CI:

- **REMOVED** apiVersions → fail the job.
- **DEPRECATED** → fail on major chart bumps; warn on patch bumps if you want less noise.

### 5. Instance gate with kubeconform

Convert target CRDs to JSON schemas using `openapi2jsonschema.py` (downloadable from the kubeconform release repository), store them in a local schema directory, and validate fixtures:

```bash
# Convert target CRDs to JSON schema:
mkdir -p src/content/manifests/eso/schemas
(
  cd src/content/manifests/eso/schemas
  openapi2jsonschema.py /path/to/target/crds/*.yaml
)

# Validate fixtures against target schemas, then fallback to default:
kubeconform -summary -output text \
  -schema-location "src/content/manifests/eso/schemas/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json" \
  -schema-location "src/content/manifests/eso/schemas/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
  -schema-location default \
  src/content/manifests/eso/*.yaml
```

Passing the local custom schema location before `default` guarantees that Custom Resources resolve against the target chart's CRD schemas immediately rather than timing out against remote discovery. `crd-compat.sh` automates this entire extraction, schema generation, and validation step when `--run-kubeconform` or `--all-gates` is passed.

### 6. Map impact to cluster resources

Before merge, answer in the PR:

| Kind | Scope | Who owns instances? | Fixture updated? | Live inventory checked? |
|---|---|---|---|---|
| SecretStore | namespaced | app teams | yes/no | yes/no |
| ClusterSecretStore | cluster | platform | yes/no | yes/no |
| ExternalSecret | namespaced | app teams | yes/no | yes/no |
| ClusterExternalSecret | cluster | platform | yes/no | yes/no |
| PushSecret | namespaced | platform/app | yes/no | yes/no |
| ClusterPushSecret | cluster | platform | yes/no | yes/no |

Cluster-scoped stores are the blast-radius multipliers. One bad `ClusterSecretStore` schema or auth field change can stall secret materialization in every namespace that references it.

### 7. Apply with eyes open

Helm will not save you. Prefer an explicit CRD apply path (separate GitOps Kustomization, Job, or manual `kubectl apply` with a change window) after consumers are migrated.

Check storage versions before dropping an API:

```bash
kubectl get crd \
  externalsecrets.external-secrets.io \
  secretstores.external-secrets.io \
  clustersecretstores.external-secrets.io \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.storedVersions}{"\n"}{end}'
```
On clusters upgraded through earlier transitions, applying the new CRD can fail if Kubernetes refuses to remove a version from `spec.versions` while it still appears in `status.storedVersions`, even if no live resources use it:

>[!ERROR]
>CustomResourceDefinition ... is invalid: status.storedVersions[0]: Invalid value: "v1alpha1": missing from spec.versions

Before modifying `storedVersions`, ensure all live resources in etcd are rewritten to a supported version (e.g., via `kube-storage-version-migrator` or `kubectl get <kind> -A -o yaml | kubectl replace -f -`). Once live objects are migrated, patch `status.storedVersions` to drop the retired version:

```bash
kubectl patch crd clustersecretstores.external-secrets.io --subresource=status --type=merge -p '{"status":{"storedVersions":["v1beta1"]}}'
```
Repeat the patch for `externalsecrets.external-secrets.io` and `secretstores.external-secrets.io` CRDs.

---

## CI: fail the PR when a Helm chart CRD bump is incompatible

Goal: whenever the chart version pin changes, CI extracts old/new CRDs and runs the three gates. Same script locally and on GitHub Actions runners.

This repository ships a copy-paste workflow at [`crd-compat.yml`](/workflow/crd-compat.yml). Drop it into your chart-pin repo as `.github/workflows/crd-compat.yml` and scope `on.pull_request.paths` to your pins and fixtures. [`crd-compat.sh`](/blog-scripts/crd-compat.sh) compares **one** chart pin delta (`OLD_VER` → `NEW_VER`), shallow clones rendered CRDs into `src/content/.crd-compat/work/`, and runs crdify on paired CRDs (with optional `--run-pluto` and `--run-kubeconform` flags for fixture validation):

```text
OLD_VER=0.16.2 NEW_VER=0.17.0 src/content/scripts/crd-compat.sh
```
>[!NOTE]
>The script and GitHub workflow illustrate how to wire these gates into CI. Adapt repository URLs, fixture directories, and target paths to your chart and CRD layout.

When a PR jumps past both `v0.16.0` and `v0.17.0`, run the script **once per minor hop** (for example `0.15.2` → `0.16.1`, then `0.16.2` → `0.17.0`) so each hard break gets its own crdify pass instead of hiding both behind one `0.15` → `0.17` tarball diff.

Wire the same pattern into the repo that pins operator charts: extend `on.pull_request.paths` to your `Chart.yaml`, `Chart.lock`, and values files, and derive `OLD_VER` / `NEW_VER` from the git diff of the pin.

### What [`crd-compat.sh`](/blog-scripts/crd-compat.sh) does

1. Fetch rendered CRDs for exactly two release tags (`OLD_VER`, `NEW_VER`) via shallow git sparse-checkout, materialize them under `src/content/.crd-compat/work/`, and run **crdify** on every paired CRD (matched by Kubernetes `metadata.name`).
2. Run **Pluto** on [`manifests/eso/`](/manifests/eso/externalsecret.yaml) when enabled via `--run-pluto` / `--pluto` or `RUN_PLUTO=true` (core kinds on `v1`; `PushSecret` stays on documented alpha for the target chart).
3. Run **kubeconform** when enabled via `--run-kubeconform` / `--kubeconform` or `RUN_KUBECONFORM=true` (automatically generates JSON schemas from target CRDs into `src/content/manifests/eso/schemas/` using `openapi2jsonschema.py`, then validates fixtures).
4. Exit non-zero on any hard failure.

Local reproduction:

```bash
# Schema comparison only (crdify)
OLD_VER=0.15.2 NEW_VER=0.16.1 src/content/scripts/crd-compat.sh
OLD_VER=0.16.2 NEW_VER=0.17.0 src/content/scripts/crd-compat.sh

# With Pluto deprecation scan on fixtures
OLD_VER=0.16.2 NEW_VER=0.17.0 src/content/scripts/crd-compat.sh --run-pluto

# With all fixture gates enabled (Pluto + kubeconform)
OLD_VER=0.16.2 NEW_VER=0.17.0 src/content/scripts/crd-compat.sh --all-gates
```

### Detecting the pin in your Git repo

For Application repos, add logic before the script runs:

Pseudo-logic for the version detect:

```bash
BASE_REF="${GITHUB_BASE_REF:-main}"
# Extract the pinned chart version (or .appVersion if tracking the operator binary directly)
OLD_VER="$(git show "origin/${BASE_REF}:path/to/Chart.yaml" | yq '.version // .appVersion')"
NEW_VER="$(yq '.version // .appVersion' path/to/Chart.yaml)"
if [[ "${OLD_VER}" == "${NEW_VER}" ]]; then
  echo "No chart version bump; skipping CRD gates"
  exit 0
fi
```

Adjust to however you pin ESO (umbrella dependency, Renovate `helm-values`, raw tag in values).

### What green CI does *not* mean

Green means: schema diff reviewed by automation, fixtures' apiVersions are acceptable, fixtures validate against new schemas.

Green does **not** mean: every namespace in every cluster was migrated, conversion webhooks are healthy, or Helm applied CRDs safely. That is still an apply-time operational checklist.

---

## Guardrails that prevent cluster-wide damage

### Helm CRD lifecycle

- Expect install-once behavior for `crds/`.
- Never assume `helm upgrade` mutates CRDs.
- Prefer a dedicated CRD package or GitOps path with explicit human approval for CRD applies.
- Deleting a CRD deletes all custom resources of that type. Treat CRD delete as data-loss territory.

### Server-side apply and managedFields

CRD objects are frequently applied with SSA by Flux, Argo CD, or `kubectl apply --server-side`. Field managers that own `spec.conversion` will fight you when a new chart removes a conversion webhook. Patch the conversion strategy deliberately, or replace ownership, rather than retrying a dry-run in a loop.

>[!NOTE]
>Server-Side Apply (SSA) resolves merges using field ownership tracked in `metadata.managedFields`. You can update fields your manager owns. Fields omitted from your intent manifest remain unchanged on the cluster, while modifying fields owned by another manager triggers a conflict unless forced.

### Migration before serve-removal

For any operator that unserves an API version:

1. Dual-serve release in production.
2. Rewrite Git and live objects.
3. Confirm discovery and Pluto.
4. Then remove the old version.

Skipping step 2 is how ESO `0.17.0` breaks clusters that "only" bumped the Helm chart.

### Inventory before apply

```bash
kubectl get externalsecrets,secretstores,clustersecretstores,pushsecrets -A \
  -o custom-columns=NS:.metadata.namespace,KIND:.kind,NAME:.metadata.name,API:.apiVersion
```

Reject the change window if anything still reports a removed apiVersion.

### Blast radius controls

- Change `ClusterSecretStore` and cluster-scoped CRDs in a dedicated PR.
- Keep fixture coverage for every kind you run in production.
- Stage: non-prod → prod.
- Document rollback *limits* (storage version moves may block naive downgrades).

### Major vs minor judgment

| Version / change type | Default CI policy | Human requirement |
|---|---|---|
| Patch, optional fields only | crdify + kubeconform | Short PR note |
| Minor with new optional fields | same | Confirm no new `required` |
| Minor/major with new `required`, removals, type/enum tighten | fail until fixtures updated | Migration notes + owner sign-off |
| Served apiVersion removal | fail until Pluto clean | Dual-serve bridge + inventory |

Field-level expectations for agents and humans are spelled out in [`SKILL.md`](/skills/crd-helm-version-guardrails/SKILL.md).

---

## What we tried that does not work well enough alone

**Changelog reading only.** Humans miss CRDs buried in "chore" PRs. Automation has to compare the actual CRD YAML.

**`helm diff` / template diff only.** Templates rarely include CRDs from `crds/`. You can ship a silent CRD landmine with a boring Deployment diff.

**Cluster dry-run as the only gate.** Useful, but it needs a cluster, credentials, and already-applied intermediate states. Keep it optional; do not block open-source-friendly CI on it.

**Schema diff without apiVersion scanning.** ESO `v0.17.0` is the counterexample.

---

## FAQ

### How do I spot breaking CRD changes when a Helm chart version is bumped?

Extract CRDs from the old and new chart versions, run `crdify` on each pair, scan consumer manifests with Pluto, and validate fixtures with kubeconform against the new schemas. Fail the PR if any hard gate fails.

### Is crdify enough by itself?

No. crdify is the right primary *schema* tool for local and GitHub Actions use. Pair it with Pluto for apiVersion removal and kubeconform for instance validity. `crdiff` can complement directory-wide OpenAPI summaries.

### What broke between External Secrets v0.15.x and v0.17.0?

Two independent hard stops: at **`v0.16.0`**, conversion webhooks come off core CRDs and **`v1alpha1` is no longer served** on `ExternalSecret`, `SecretStore`, and cluster counterparts (see [v0.16.0 release notes](https://github.com/external-secrets/external-secrets/releases/tag/v0.16.0)). At **`v0.17.0`**, **`v1beta1` is deprecated and unserved in a single minor step.** Migrate core manifests to `external-secrets.io/v1` on the **`v0.16.2`** dual-serve bridge first (see [v0.17.0 release notes](https://github.com/external-secrets/external-secrets/releases/tag/v0.17.0)). A one-shot chart bump from `0.15.x` to `0.17.0` without per-hop CRD comparison misses the first break entirely.

### Should kubeconform validate my whole umbrella chart?

Ideal eventually. For this workflow we keep CI fixtures focused on the CR kinds you care about (`ExternalSecret`, `SecretStore`, `ClusterSecretStore`, `PushSecret`) so the gate stays fast and deterministic.

### Where is the checklist agents should follow?

[`SKILL.md`](/skills/crd-helm-version-guardrails/SKILL.md) provides the complete decision matrix and checklist for platform teams and automated agents.

---

## Put the gates in the repo that owns the chart pin

Copy the fixture set from [`manifests/eso/`](/manifests/eso/externalsecret.yaml), wire in [`crd-compat.sh`](/blog-scripts/crd-compat.sh) (or equivalent), and make chart version bumps open a PR that cannot merge while crdify, Pluto, or kubeconform fail.

When the next Renovate PR bumps External Secrets (or cert-manager, Gatekeeper, Istio CRDs, …), you want the failure in CI, not in the secret sync path at 2 a.m.

---

## Reference

- [Server-side apply (concepts)](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
- [`kubectl apply --server-side`](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_apply/#server-side)
- [CustomResourceDefinitions](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/) (serving versions, `storedVersions`, conversion)
- [Helm chart best practices — CRDs](https://helm.sh/docs/chart_best_practices/custom_resource_definitions/)
- [crdify](https://github.com/kubernetes-sigs/crdify) (`sigs.k8s.io/crdify`)
- [Pluto](https://github.com/FairwindsOps/pluto) (deprecated / removed apiVersions)
- [kubeconform](https://github.com/yannh/kubeconform) (manifest validation against schemas)
- [crdiff](https://github.com/xrstf/crdiff) (optional OpenAPI directory diff complement to crdify)
- [Renovate](https://github.com/renovatebot/renovate)