---
name: argocd-helm-master-repo-guardrails
description: >
  Note: this skill file is not yet optimised for context efficiency, env
  reliability, or CI speed. It is a work in progress.

  Apply Argo CD master-repo best practices when authoring or reviewing
  ApplicationSets that install Helm charts or embed KubeVela/OAM Applications.
  Enforce goTemplate missingkey=error, pinned targetRevision, Helm valueFile
  layering with ignoreMissingValueFiles, RollingSync by region, ServerSideApply,
  template-time validation, and rich ownership labels. Use this skill whenever
  the user edits Argo CD Application or ApplicationSet manifests, master-repo
  Helm charts, multi-cluster GitOps rollouts, Progressive Sync / RollingSync,
  Helm valueFiles for Argo, KubeVela apps delivered via Argo CD, multi-cluster
  Argo CD master repos, or asks how to safely install Helm charts across clusters.
---

# Argo CD Helm master-repo guardrails

Platform/GitOps checklist for ApplicationSets that deliver Helm charts (and
KubeVela/OAM apps). Companion narrative:
[argocd-helm-master-repo-best-practices.md](../argocd-helm-master-repo-best-practices.md).

For CRD schema breaks on chart bumps, also load
[crd-helm-version-guardrails](../crd-helm-version-guardrails/SKILL.md).

## When this skill applies

- New or changed `Application` / `ApplicationSet` YAML in a master repo.
- Helm chart install or version pin changes driven by Argo CD.
- Multi-cluster / multi-region rollout design (RollingSync, generators).
- Embedding KubeVela `Application` (OAM) inside Argo Helm values.
- Reviews that mention `goTemplate`, `missingkey=error`, `ServerSideApply`,
  `ignoreMissingValueFiles`, or `targetRevision: HEAD`.

## Out of scope

- **AppProject** design (destination allow/deny, source-repo allowlists, cluster
  resource whitelists, `project: default` policy). That is org RBAC and varies
  too much to encode here. Do not hard-fail or warn on AppProject shape in the
  §12 CI matrix for this skill.
- Full Argo CD install/HA topology beyond optional geo-shard scale-out notes.
- Implementing Kyverno policies themselves (only when to complement Helm `fail`).

## Required outputs before merge

Record these fields in the PR (or agent summary):

| Field                     | Value                                                                |
| ------------------------- | -------------------------------------------------------------------- |
| `appSetName`              | ApplicationSet metadata.name                                         |
| `chartRepo` / `chartPath` | Helm source location                                                 |
| `targetRevision`          | Pinned version or coalesced platform version (not `latest`)          |
| `destinations`            | Cluster selector / regions covered                                   |
| `managementTopology`      | `single` or `geo-sharded` (optional scale-out)                       |
| `valueFiles[]`            | Layered values paths                                                 |
| `ignoreMissingValueFiles` | `false` (default) or `true` + list of optional paths                 |
| `syncMode`                | `automated` (default) or `manual` for critical/prod propagation      |
| `syncOptions[]`           | e.g. `ServerSideApply=true`, `CreateNamespace=true`                  |
| `rollingSync`             | Steps / `maxUpdate` or `n/a` with reason                             |
| `labels[]`                | team, region, cluster, appset, platform-version                      |
| `kubevela`                | `no` / `nested-helm-values` / `dedicated-source` + image/traits pins |
| `crdImpact`               | `none` or link to CRD gate results                                   |

## Procedure

### 1. Confirm master-repo separation

- Desired _where/how_ (ApplicationSets, sync policy, valueFiles) lives in the
  master repo.
- Chart source / app code stays in its own repo unless this PR intentionally
  changes the chart.
- Prefer master repo shaped as a Helm chart that renders ApplicationSets.

**Fail** if app CI and config changes share one repo in a way that risks
infinite build loops, with no documented exception.

### 2. Prefer ApplicationSet + cluster generators

```yaml
generators:
  - clusters:
      selector:
        matchExpressions:
          - key: aws_region_name
            operator: In
            values: [us-west-2]
```

- One AppSet per logical service/platform component.
- Region/cluster selectors define blast radius.
- **Geo-sharding is optional scale-out**, not required for every multi-region
  fleet. A single management cluster is fine until reconciliation load or
  failure-domain risk justifies a split.
- Require geo-sharded management destinations only past a documented threshold
  (example: many regions _and_ hundreds of Applications, or repeated Argo CD
  controller saturation). Record `managementTopology: single|geo-sharded` in
  the PR when platform AppSets change.

### 3. Enable strict Go templating

Required on ApplicationSets that interpolate cluster values:

```yaml
goTemplate: true
goTemplateOptions: [missingkey=error]
```

**Fail** on missing `missingkey=error` when templates reference `.values.*`.

### 4. Pin revisions

- Set explicit `targetRevision` (semver / chart version / git tag or SHA).
- **Platform umbrellas:** pin map `platformVersions` (`global`, optional
  `releaseGroupN`, optional per-cluster keys) plus membership map
  `releaseGroups` (group id → cluster names; id `"2"` → pin key
  `releaseGroup2`). Inject both as JSON on cluster generator `values`
  (`mustToJson` / `mustFromJson`). Resolve with `templatePatch` and Sprig
  `coalesce` (cluster → release-group → global); label the resolved pin.
- **release group** = rollout cohort sharing one group pin, not a geo-shard
  (see companion blog Practice 5).

**Fail** on `HEAD` / `latest` for CRD-shipping charts and platform operator
charts (ingress, ESO, Kyverno, CSI, observability operators, etc.).

**Warn** (do not block) on app/enablement AppSets that still float `HEAD`, and
require a one-line risk note in the PR (non-prod developer tooling only).

### 5. Layer Helm valueFiles

```yaml
helm:
  valueFiles:
    - values.yaml
    - values-dev.yaml
    - values-dev-{{ .values.awsRegionName }}.yaml
  # Default: omit ignoreMissingValueFiles (fail if a listed file is missing).
  # Opt in only when sparse regional overlays are intentional:
  # ignoreMissingValueFiles: true
```

- Defaults → env → env+region.
- **Default `ignoreMissingValueFiles` off** so typos like `values-dev-us-west-2.yaml`
  fail loud instead of silently skipping.
- Set `ignoreMissingValueFiles: true` only with a PR note listing which regional
  files are optional.
- Inject cluster facts (`aws_region`, `vpc_id`, `eks_cluster`, …) via generator
  values / `helm.values`, not hardcoded account IDs in the chart.

### 6. Progressive rollout

For multi-region AppSets, default to **region steps only** (not env-first).
Env promotion (`dev` → `qa` → `prd`) is a separate master-repo / values
process, not a RollingSync concern inside one AppSet.

```yaml
strategy:
  type: RollingSync
  rollingSync:
    steps:
      - matchExpressions:
          - key: aws-region
            operator: In
            values: [us-west-2]
        maxUpdate: '1'
```

- Label generated Applications with `aws-region` so steps can match.
- Consider `deletionOrder: Reverse` when teardown order matters.
- Single-cluster / low-risk AppSets may omit RollingSync; document why.
- Do not invent env-step RollingSync as a substitute for separate env pins.

### 7. Sync policy and apply mode

**Default (A):** automated sync everywhere, backed by pinned revisions, region
RollingSync, and CRD gates.

```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
revisionHistoryLimit: 3
```

**Critical path override (C):** use **manual sync** (omit `automated`) when
propagation must wait for human intervention. Typical cases:

- Prod platform / CRD-shipping chart bumps after non-prod has proven the pin
- First-time SSA migration or conversion-webhook CRD changes
- Any change window where RollingSync alone is not enough operational control

Record `syncMode: manual` in the PR and who will click sync / run the wave.

- Default remains **universal** when automated: `ServerSideApply=true`,
  `prune: true`, `selfHeal: true`. Do not invent a quieter prune-off default
  for operators while automated is on.
- Use `ServerSideApply=true` for large objects and CRD-heavy Helm charts.
- Do not track HPA-owned fields (e.g. `replicas`) in Git if HPA manages them.
- **Caveat (required in PR when relevant):** prune deletes anything removed from
  desired state. Chart bumps that drop PVC/CRD/templates, or CRD conversion fights
  under SSA, need an explicit risk note before merge — the default stays on.

### 8. Template-time validation (primary) + Kyverno (complement)

**Default (A):** hard `fail` in the master-repo Helm chart before ApplicationSet
render succeeds:

- Namespace prefix / tenancy checks.
- Region allow-lists.
- Reject values that would sync a chart into the wrong destination.

Broken values must not become Applications. Accept that a bad entry can block
rendering of that AppSet until fixed; that is preferred over a wrong-tenancy sync.

**Complement (C):** invoke **Kyverno** (or similar) for policies that are awkward
or unsafe to encode only in Helm `fail`, for example:

- Constraints that must evaluate against _live_ cluster state
- Cross-app / fleet-wide rules that should not live in every master-repo chart
- Guardrails on already-rendered Applications when multiple master repos exist

Do not replace template-time tenancy `fail` with Kyverno alone. Use Kyverno to
extend coverage, not to make master-repo templates "dumb" by default.

### 9. Labels and ownership

Every generated Application should carry at least:

| Label                    | Purpose                               |
| ------------------------ | ------------------------------------- |
| `appset`                 | Parent ApplicationSet name            |
| `team`                   | Owning team                           |
| `aws-region` / env label | RollingSync + filters                 |
| cluster identity label   | e.g. `argocd-cluster` / `eks-cluster` |
| `platform-version`       | When platform pin coalescing is used  |

### 10. KubeVela / OAM path (when applicable)

Two delivery shapes are allowed; the PR must pick **one** and record it:

| Shape                                          | When to use                                                                      |
| ---------------------------------------------- | -------------------------------------------------------------------------------- |
| Nested OAM under Helm `values.resources`       | Existing enablement AppSets; single Helm release wraps the OAM app               |
| Dedicated Argo source path / chart of OAM YAML | Cleaner diffs; no double renderer when you are not already on the nested pattern |

Either way:

- Pin image tags and traits/component chart revisions (same `HEAD` rules as §4).
- Apply the same sync options, labels, and region RollingSync rules.
- Do not introduce a second GitOps engine for the same workload.
- Note the chosen shape in `kubevela` / PR summary (`nested-helm-values` or `dedicated-source`).

### 11. CRD-bearing chart bumps

If `targetRevision` moves an operator that ships CRDs:

1. Run [crd-helm-version-guardrails](../crd-helm-version-guardrails/SKILL.md) (crdify + Pluto + kubeconform).
2. Record `crdImpact` in the PR.
3. Do not rely on `helm upgrade` to mutate existing CRDs.

### 12. CI enforcement (soft warnings + hard fails)

Do not leave this skill as docs-only. master-repo CI should combine **B** (warn)
and **C** (block).

**Hard fail (exit non-zero):**

| Check                                 | Rule                                                         |
| ------------------------------------- | ------------------------------------------------------------ |
| `helm template` / master-repo render  | Tenancy/region `fail` in templates surfaces here             |
| `goTemplateOptions`                   | Missing `missingkey=error` when templates use `.values.*`    |
| Operator / CRD chart `targetRevision` | `HEAD` / `latest` blocked                                    |
| Multi-region AppSet                   | Missing region `RollingSync` steps                           |
| `ignoreMissingValueFiles: true`       | Fail unless PR body / values annotation lists optional paths |
| CRD-shipping pin bump                 | CRD gates (crdify + Pluto + kubeconform) must pass           |

**Soft warn (annotate PR, do not block by default):**

| Check                                   | Rule                                                                 |
| --------------------------------------- | -------------------------------------------------------------------- |
| App / enablement `targetRevision: HEAD` | Warn + require one-line risk note                                    |
| Missing ownership labels                | Warn on absent `team` / `aws-region` / `appset`                      |
| Automated vs manual sync                | Warn when prod/CRD AppSet stays automated with no change-window note |
| Geo-sharding                            | Warn only if threshold signals exist and topology is still `single`  |
| KubeVela shape                          | Warn if OAM present but shape / pins not recorded                    |

Promote a warn to fail for a repo once false positives are low. Start soft on
labels and enablement `HEAD`; keep operator pins and `missingkey=error` hard
from day one.

## Decision table

| Change                                                                   | Default policy                     | Human note required                                    |
| ------------------------------------------------------------------------ | ---------------------------------- | ------------------------------------------------------ |
| New optional Helm value                                                  | Allow                              | Short PR note                                          |
| Single Argo CD management cluster                                        | Allow                              | Default until threshold hit                            |
| Geo-shard management (AMER/APAC/EMEA)                                    | Opt-in scale-out                   | Threshold: regions + app count / controller saturation |
| `ignoreMissingValueFiles: true`                                          | Opt-in only                        | List which regional files may be absent                |
| New region in selector                                                   | Allow with region RollingSync step | Blast-radius review                                    |
| Env-first RollingSync inside one AppSet                                  | Avoid                              | Use separate env pins / master repos instead           |
| Float `targetRevision` to HEAD (CRD/operator)                            | Block                              | Pin or dual-serve bridge first                         |
| Float `targetRevision` to HEAD (app/enablement)                          | Warn                               | One-line risk note in PR                               |
| Automated sync (default)                                                 | Prefer on                          | Rely on pins + region RollingSync + CRD gates          |
| Manual sync (critical/prod propagation)                                  | Opt-in                             | Who syncs, change window, rollback owner               |
| Enable prune on stateful chart                                           | Review                             | PVC/CRD deletion risk                                  |
| Add SSA                                                                  | Prefer on                          | Field-manager migration if CSA legacy                  |
| Embed new KubeVela traits                                                | Allow if pinned                    | Trait version + image pins                             |
| KubeVela delivery shape                                                  | Pick one                           | `nested-helm-values` or `dedicated-source`             |
| Template-time Helm `fail` (tenancy/region)                               | Prefer on                          | Accept AppSet render block until fixed                 |
| Kyverno on rendered Applications                                         | Complement                         | Live-state / fleet-wide rules Helm should not own      |
| CRD schema / apiVersion break                                            | Block until CRD gates pass         | Bridge version + inventory                             |
| CI: missing `missingkey=error` / operator `HEAD` / no region RollingSync | Hard fail                          | See §12                                                |
| CI: enablement `HEAD` / missing labels                                   | Soft warn                          | Promote to fail per-repo when ready                    |
| AppProject / `project: default` policy                                   | Out of scope                       | Org RBAC; not part of this skill’s CI                  |

## Agent behavior

1. Do not claim an ApplicationSet is "safe" from UI screenshots or changelog text alone.
2. Prefer patching the master-repo AppSet to meet this checklist over one-off
   `argocd app create` advice.
3. Sanitize account IDs, tokens, and internal hostnames in examples and PR text.
4. Link readers to
   [argocd-helm-master-repo-best-practices.md](../argocd-helm-master-repo-best-practices.md)
   for narrative context; keep this file as the executable checklist.
5. When CRDs are in scope, chain to [crd-helm-version-guardrails](../crd-helm-version-guardrails/SKILL.md).
6. Prefer adding or updating the §12 CI checks over one-off review comments.
7. Do not commit or push unless the user asks.
