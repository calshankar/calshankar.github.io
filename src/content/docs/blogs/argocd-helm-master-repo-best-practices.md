---
title: Argo CD Patterns for Helm Chart Installs with ApplicationSets to Survive Multi-Cluster Reality
description: Best practices from multi-cluster Argo CD ApplicationSets for installing Helm charts and  manifests.
sidebar:
  order: 5
---
*By Shankar Ramanathan*

Ad-hoc Argo CD Applications are fine until you install the same Helm chart across dozens of clusters and one missing valueFile, unpinned `targetRevision`, or CRD apply fight takes half the fleet with it.

The patterns below come from real master helm repos under a multi-cluster platform layout: ApplicationSets that wrap Helm chart installs, geo-sharded management clusters, progressive `RollingSync`, and the same delivery path used for Vanila K8s manifest or [KubeVela/OAM apps](/blogs/progressive-delivery-part1).

Both platform and GitOps engineers should find the checklist useful. Sanitize the labels Accordingly for your own org.

The reusable agent/human checklist(WIP) lives in [argocd-skill](/public/skills/argocd-appset/SKILL.md). Use that on every ApplicationSet or Helm pin change in a master helm repo.

---

## What a master helm repo is (and why it is not your app repo)

Argo CD's docs recommend separating configuration from application source. The practical form we use is stronger than "a folder of YAML": the master helm repo *is a Helm chart* whose templates emit `ApplicationSet` (and sometimes `Application`) objects.

```
  [ App / Umbrella chart repos ]      [ master helm repo = Helm chart ]
           │                                    │
           │  chart versions, OAM apps          │  ApplicationSets + values file
           │                                    ▼
           │                         [ Argo CD management cluster ]
           │                                    │
           └────────────────────────────────────┼──► workload clusters
                                                │
                                     cluster generator fans out
                                     one Application per cluster
```

**Why this helps Helm installs:** chart bumps live in the chart repo or a version pin in values. Desired *where/how* the chart is installed (clusters, regions, sync policy, valueFiles) lives in the master helm repo. You can change replica overlays or region rollout order without triggering the app CI loop that Argo warns about when config and source share one git history.

**Why this helps:** Whether it is Git repo hosting Platform Umbrella chart, custom(OAM `Application`) or vanila K8s manifest, it can sit inside Git repo hosting charts or even Helm `values:` on the Argo ApplicationSets/Application. Delivery mechanics stay identical; only the artifact changes.

---

## Practice 1: ApplicationSet + cluster generators instead of copy-paste Applications

One ApplicationSet selects registered clusters by label and stamps an Application per match.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: example-service
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchExpressions:
            - key: aws_region_name
              operator: In
              values:
                - us-west-2
                - eu-central-1
        values:
          # cluster-scoped defaults injected into every generated app
          team: app-team
  goTemplate: true
  goTemplateOptions: [missingkey=error]
  template:
    metadata:
      name: 'example-service-{{ .values.awsRegionShortname }}'
      labels:
        appset: example-service
        aws-region: '{{ .values.awsRegionName }}'
        team: app-team
    spec:
      project: default
      destination:
        name: '{{ .values.argocdCluster.name }}'
        namespace: example-service
      source:
        repoURL: https://charts.example.com/example-service
        targetRevision: 1.4.2
        path: .
        helm:
          releaseName: example-service
```

**Why:** adding a cluster to the registry (with the right labels) is enough for the Helm chart to land there. You do not maintain N nearly identical Application manifests. Region selectors are the blast-radius knob: a bad chart version can be limited to the regions listed in `values` before you widen the selector.

---

## Practice 2: Geo-shard management clusters when Argo CD itself needs to scale

This is an **optional scale-out**, not a prerequisite for multi-region Helm. A single management cluster is fine until reconciliation load or failure-domain risk justifies a split (many regions *and* a large Application count, or repeated controller saturation).

When you do shard, platform ApplicationSets often use cluster generators  per GEO (americas / asia-pacific / europe), each pointing generated apps at a different management cluster destination.

```yaml
spec:
  generators:
    - clusters:
        selector:
          matchExpressions:
            - key: aws_region_name
              operator: In
              values: [us-east-1, us-west-2, ca-central-1]
        values:
          argocdManagementClusterName: mgmt-americas
    - clusters:
        selector:
          matchExpressions:
            - key: aws_region_name
              operator: In
              values: [ap-southeast-1, ap-northeast-1]
        values:
          argocdManagementClusterName: mgmt-asia-pacific
    - clusters:
        selector:
          matchExpressions:
            - key: aws_region_name
              operator: In
              values: [eu-central-1, eu-west-1]
        values:
          argocdManagementClusterName: mgmt-europe
  template:
    spec:
      destination:
        name: '{{ .values.argocdManagementClusterName }}'
        namespace: argocd
```

**Why for Helm:** the Umbrella Helm chart that installs multiple application or Platform addons (ingress, observability, policy) is still one source of truth in git with versioned releases. Reconciliation load and failure domains split across management planes. A stuck sync in one geo does not serialize the entire world behind one Argo CD.

**Do not** geo-shard on day one "because best practices." Prefer one management plane until the threshold is real; sharding early doubles secrets, RBAC, and upgrade toil without buying you capacity you do not need yet.

Geo-shards are not the same as **release grouping** (Practice 5). Shards pick *which management plane* reconciles a region; release groups pick *which umbrella chart revision* a cluster runs during a staged bump. A fleet can use both.

---

## Practice 3: `goTemplate` with `missingkey=error`

Almost every production ApplicationSet in this layout sets:

```yaml
goTemplate: true
goTemplateOptions: [missingkey=error]
```

**Why:** default Go template behavior treats missing keys as empty strings. Empty strings become valid-looking Helm values (`aws_vpc_id: ""`) and you discover the bug after the chart installs into the wrong networking context. `missingkey=error` fails ApplicationSet render instead. That is the same spirit as the Argo CD recommendation that landed `missingkey=error` support for ApplicationSets: undefined keys should be loud.

For Helm and other manifests, loud failure beats a successful sync of a chart with silently blank overrides.

---

## Practice 4: Helm valueFile layering (and when to allow missing files)

Layer defaults, then env, then env+region. Keep listed files real by default so a typo cannot silently skip an override.

```yaml
source:
  repoURL: https://github.com/example/service-chart
  targetRevision: 2.3.0
  path: charts/service
  helm:
    releaseName: service
    valueFiles:
      - values.yaml
      - values-dev.yaml
      - values-dev-{{ .values.awsRegionName }}.yaml
    # Default: do not set ignoreMissingValueFiles.
    # Opt in only when sparse regional overlays are intentional:
    # ignoreMissingValueFiles: true
    values: |
      env: dev
      aws_region: "{{ .values.awsRegionName }}"
      eks_cluster: "{{ .values.eksCluster.name}}"
      image:
        tag: 2.3.0
```

**Why:** Helm charts rarely ship one values file that fits every cluster. Layering keeps shared defaults in `values.yaml`, environment policy in `values-<env>.yaml`, and regional exceptions only where they exist.

**Default `ignoreMissingValueFiles` off.** A misspelled `values-dev-us-west-2.yaml` should fail the sync, not install the chart with blank regional policy. Turn the flag on only when you deliberately omit per-region files and document which paths may be absent in the PR. The alternative without the flag is committing empty regional stubs; that is noisier in git but safer than silent skips.

---

## Practice 5: Pin `targetRevision` (and coalesce platform versions with `templatePatch`)

Argo's best practices say that the remote Helm/Kustomize bases must be immutable. Tracking `HEAD` of a chart repo means yesterday's sync and today's sync can differ with no commit in *your* Platform helm repo.

Preferred shape for product charts:

```yaml
source:
  repoURL: https://charts.example.com/external-secrets
  targetRevision: 0.16.2   # pin; do not use latest
  chart: external-secrets
```

A **platform umbrella** is the large chart those ApplicationSets install (addons, operators, CRDs). The master helm repo is still just the chart that *emits* ApplicationSets; the umbrella is what each generated Application pins with `targetRevision`.

For staged umbrella rollouts, pins usually live in one values map and resolve per cluster with `templatePatch`.

A **release grouping** is a named cohort of clusters that share one pinned umbrella revision during that rollout. Membership is a map of group id → cluster names (often `"1"`, `"2"`, `"3"`). The pin for that cohort sits under a parallel key like `releaseGroup1`. Early cohorts (management planes, canaries) bump the group pin first; everyone else stays on `global` until promoted. In some test fleets group ids line up with geos; in live fleets they are usually rollout cohorts, not regions.

```yaml
# values (anonymized) — membership vs pins are two maps
platformVersions:
  global: 1.0.0
  releaseGroup1: 1.1.0   # early cohort
  releaseGroup2:          # empty → falls through to global
releaseGroups:
  "1": [mgmt-usw2, canary-euw1]
  "2": [workload-a, workload-b]
```

Group id `"2"` in `releaseGroups` pairs with pin key `releaseGroup2` in `platformVersions` (`printf "releaseGroup%s"` in `templatePatch`). Cluster generators pass both maps as JSON strings (`mustToJson` in generator `values`, `mustFromJson` inside `templatePatch`) because Go text templates on ApplicationSets only interpolate string fields.

Precedence (Sprig `coalesce` = first non-empty argument):

1. Per-cluster key in `platformVersions`
2. `releaseGroup{N}` for the cohort that lists the cluster for canary release
3. `global`

`templatePatch` merges a Go-templated YAML patch onto the ApplicationSet template after generators run—needed when `targetRevision` must be computed from those maps rather than hard-coded in the base template:

```yaml
templatePatch: |
  {{- $clusterReleaseGroup := "" }}
  {{- $releaseGroups := mustFromJson .values.releaseGroups }}     ## Go text templates on ApplicationSets
  {{- $platformVersions := mustFromJson .values.platformVersions }} # only interpolate string fields.
  {{- range $key, $list := $releaseGroups }}
    {{- if has $.values.argocdCluster.name $list }}
      {{- $clusterReleaseGroup = $key }}
    {{- end }}
  {{- end }}
  {{- $clusterVersion := index $platformVersions .values.argocdCluster.name }}
  {{- $releaseGroupVersion := index $platformVersions (printf "releaseGroup%s" $clusterReleaseGroup) }}
  {{- $platformVersion := coalesce $clusterVersion $releaseGroupVersion $platformVersions.global }}
  metadata:
    labels:
      # sanitize non-semver pins (branch names) before using as a label
      platform-version: "{{ $platformVersion }}"
  spec:
    source:
      targetRevision: "{{ $platformVersion }}"
```

**Why:** canaries get an explicit newer pin; everyone else stays on `global`. Git history of the Platform helm repo values becomes the audit log for "which chart meaning ran where." That matches Argo's immutability guidance without forcing a hard cutover of every cluster in one PR.

Whether it is **release group version pins** or `RollingSync`, the progressive delivery achieves the Same goal, with different knobs whether it is umbrella chart via pinning or native progressive sync for your Application helm chart for a staggered rollout of AppSets to stage blast radius within a region.

**Trade-off:** some enablement apps still use `targetRevision: HEAD` for speed. Treat that as an explicit exception for non-prod developer tooling, not the default for operators that ship CRDs.

When the chart ships CRDs, pair this pin discipline with the gates in [Spot Breaking CRD Changes Before Your Helm Chart Bump Hits the Cluster](./spotting-crd-breaking-changes-helm.md).

---

## Practice 6: `RollingSync` by region (Progressive Sync)

```yaml
spec:
  strategy:
    type: RollingSync
    rollingSync:
      steps:
        - matchExpressions:
            - key: aws-region
              operator: In
              values: [us-west-2]
          maxUpdate: "1"
        - matchExpressions:
            - key: aws-region
              operator: In
              values: [us-east-1]
          maxUpdate: "1"
        - matchExpressions:
            - key: aws-region
              operator: In
              values: [eu-central-1]
          maxUpdate: "1"
```

**Why for Helm:** a chart bump that breaks admission or a webhook should burn one region first, not all generated Applications in parallel. Progressive Sync (RollingSync) is the ApplicationSet-native way to stage that. Recent Argo CD releases also add `deletionOrder: Reverse` so teardown respects the opposite of deploy order when you need ordered dependency teardown (for example staging before shared platform pieces). Start with RollingSync on deploy; add reverse deletion when your dependency graph requires it.

Default the steps to **regions** per environment and does not account for the Env promotion (`dev` → `qa` → `prd`), not as RollingSync stages inside one AppSet. Label each generated Application with the same key the steps match on (here `aws-region`) so the matchers have something stable to select. Applications not matched by any step are left out of the rolling sync and need a manual sync.

>[!NOTE]
>Argo CD’s ApplicationSet RollingSync(beta feature) only advances to the next step once all Application resources matching the current step transition to Healthy and Synced. If you have requirement to perform soak testing via Canary release process, use the native [Argo Rollout](./blogs/progressive-delivery-part2) and wrap it in your ArgoCD Application as helm chart or as OAM Application.

Use RollingSync for multi-region *product* AppSets. For the platform umbrella chart, staged delivery is often the release-group version pins in Practice 5 instead of (or in addition to) RollingSync.

>[!IMPORTANT]
>Progressive Sync is a beta controller feature: enable it on the ApplicationSet controller (`--enable-progressive-syncs` or the equivalent env/ConfigMap flag) before relying on `RollingSync` in production. See [Progressive Syncs](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Progressive-Syncs/).

---

## Practice 7: Sync options that match how Helm and CRDs actually apply

**Default:** automated sync, with prune and selfHeal on. Pins, region RollingSync, and CRD gates are the safety net so the fleet does not wait on a human for every chart bump.

```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  retry:
    limit: 1
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
revisionHistoryLimit: 3
```

**Critical path:** when propagation must wait for a change window (platform / CRD-shipping bumps, SSA/conversion migrations), omit `automated` and sync manually after non-prod has proven the pin. Record who syncs and when in the PR. RollingSync still helps once someone starts the wave; it does not replace a human gate when the blast radius is cluster-wide CRDs.

**Why each knob matters for Helm:**

| Option | Why |
|---|---|
| `automated` (default) | Keeps drift closed without ticket queues; rely on pins + region RollingSync + CRD CI |
| Manual (omit `automated`) | Critical/prod propagation where a bad pin must not self-roll |
| `CreateNamespace=true` | Chart installs often assume the namespace exists; AppSet destinations vary per cluster |
| `ServerSideApply=true` | Large CRDs and Helm-rendered objects exceed client-side apply limits; SSA improves apply reliability and diff accuracy (Argo blog theme since SSA beta, with later client-to-server migration helpers) |
| `prune` / `selfHeal` | Drifted imperative edits do not silently become the live truth |
| `revisionHistoryLimit` | Keeps Application history bounded on busy AppSets |

**Caveats:** prune deletes resources removed from the chart. That is correct for most app charts and dangerous if someone "temporarily" removed a CRD or PVC from templates. SSA plus GitOps field managers can fight leftover `spec.conversion` on CRDs.

Official Argo guidance also says leave room for imperativeness: do not track HPA-managed `replicas` in Git if HPA owns that field.

---

## Practice 8: Fail in the Helm template before Argo ever syncs

Your Helm charts can `fail` when values violate policy (namespace prefix, allowed regions):

```yaml
{{- $ns := $service.namespace | default (printf "%s-%s" $.Values.namespace_prefix $service.name) -}}
{{- if not (hasPrefix $.Values.namespace_prefix $ns) -}}
{{- fail (printf "namespace=%q must start with %q" $ns $.Values.namespace_prefix) -}}
{{- end -}}
```

**Why:** ApplicationSet YAML that renders successfully with a wrong namespace still creates an Application that syncs a Helm release into the wrong tenancy boundary. Template-time `fail` keeps the mistake in the PR (`helm template` / CI) instead of in the cluster. Region allow-lists work the same way: reject a service that asks for a region the platform does not operate. Yes, a typo can block rendering until it is fixed. That is better than a successful sync into the wrong tenancy.

**Complement with Kyverno when Helm `fail` is the wrong tool:** live-cluster checks, fleet-wide rules across multiple Platform helm repos, or policies that should not be copy-pasted into every chart. Keep tenancy/region `fail` in the Platform helm repo as the first gate; add Kyverno for the scenarios that need admission on already-rendered Applications. Do not drop template-time validation and hope Kyverno alone catches everything.

---

## Practice 9: Rich labels on every generated Application

```yaml
metadata:
  labels:
    appset: example-service
    aws-region: '{{ .values.awsRegionName }}'
    argocd-cluster: '{{ .values.argocdCluster.name }}'
    eks-cluster: '{{ .values.eksCluster.name}}'
    platform-version: '1.12.0'
    team: app-team
```

**Why:** UI filters, alert routing, and `RollingSync` matchers all depend on labels you can query. Helm release name alone is not enough when one AppSet produces fifty Applications. KubeVela apps benefit identically: ownership labels on the Argo Application are how platform teams find the OAM workload without scraping every namespace.

---

## Practice 10: Inject cluster facts into Helm values (do not hardcode them in the chart)

```yaml
helm:
  values: |
    aws_region: "{{ .values.awsRegionName }}"
    aws_account_id: "{{ .values.awsAccountId }}"
    aws_vpc_id: "{{ .values.awsVpcId }}"
    eks_cluster: "{{ .values.eksCluster.name}}"
    env: {{ .Values.applicationSets.env }}
```

**Why:** the chart stays portable. Cluster-specific networking and account IDs come from the cluster secret / generator values Argo already knows. Hardcoding account IDs inside the chart forces forks per environment. Generator `values:` plus `missingkey=error` is the contract that those fields exist before sync.

---

## Short KubeVela section: same AppSet, two allowed artifacts

[KubeVela delivery](/blogs/progressive-delivery-part1) uses the same ApplicationSet machinery. Pick **one** shape per app and pin image + traits either way.

**Shape A — nested OAM under Helm values** (common in enablement AppSets):

```yaml
source:
  helm:
    releaseName: demo-backend
    values: |
      resources:
        - apiVersion: core.oam.dev/v1beta1
          kind: Application
          metadata:
            name: demo-backend
            namespace: demo
          spec:
            components:
              - name: demo-backend
                type: webservice
                properties:
                  image: registry.example.com/demo-backend:1.2.3
                  cpu: "1"
                  memory: 1Gi
                traits:
                  - type: scaler
                    properties:
                      replicas: 2
                  - type: envfrom
                    properties:
                      configMaps:
                        - name: demo-config
```

**Shape B — dedicated source of OAM YAML** (cleaner diffs, no double renderer):

```yaml
source:
  repoURL: https://github.com/example/demo-backend-config
  targetRevision: 1.2.3
  path: oam/
```

**Why either works:** Argo CD still owns sync, health, RollingSync, and SSA. KubeVela owns component/trait composition. You do not need a second GitOps engine. Nested values are fine when you already ship that way; prefer a dedicated path when diffs of giant `values:` blocks slow reviews. Pin the image tag and traits chart/`targetRevision` the same way you pin Helm charts. `HEAD` is still a warn-only exception for non-prod enablement, and a hard fail for anything that behaves like an operator.

---

## What recent Argo recommendation themes reinforces

| Theme | How it shows up in master helm repos |
|---|---|
| Server-Side Apply (and later CSA→SSA migration) | `ServerSideApply=true` on AppSets that install large Helm/CRD payloads |
| Progressive Sync / RollingSync (+ reverse deletion) | Region-stepped Helm chart rollouts |
| `missingkey=error` for ApplicationSets | Default on generated templates |
| Separate config vs source; pin revisions | master helm repo Helm chart + explicit `targetRevision` / platform version maps |

None of these replace reading the [official best practices](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/). They are how those practices look after you have lived with multi-cluster Helm for a while.

---

## What we tried that works poorly

**One giant Application per cluster with every chart inlined.** Diffs become unreadable; a single bad chart blocks unrelated addons.

**`targetRevision: HEAD` for operators with CRDs.** Silent semantic drift; CRD breaks show up as "random" sync failures days later.

**Client-side apply for CRD-heavy platform charts.** Apply errors and managedFields fights that SSA was meant to avoid.

**`ignoreMissingValueFiles: true` as a global default.** Hides typos and ships charts without the regional overrides you thought you applied.

**No template-time validation.** Bad namespaces reach the API server as successful Application creates.

---

## Checklist (Adapt  your )

Before merging a PR that hosts your master Application Sets that installs or bumps a Helm chart (or embeds a KubeVela Application):

1. Repository holding Master helm repo change only (app source stays separate) unless the chart itself must change.
2. `targetRevision` pinned (or platform version coalesced), not floating `latest`.
3. `goTemplate: true` and `goTemplateOptions: [missingkey=error]`.
4. Helm `valueFiles` layered; leave `ignoreMissingValueFiles` off unless sparse regional overlays are documented.
5. Cluster/region selectors reviewed for blast radius.
6. `RollingSync` steps defined for multi-region AppSets.
7. Sync options include `ServerSideApply=true` when CRDs or large objects are in play; automated by default, manual for critical/prod propagation.
8. Labels present for team, region, cluster, appset.
9. Template `fail` guards for namespace/region policy; Kyverno for live/fleet rules Helm should not own.
10. Wire master-helm-repo CI as **soft warn + hard fail** (see below), not docs-only review.

---

## CI: warn on the soft stuff, fail on the sharp edges

Reviewers alone will not keep `missingkey=error` and operator pins honest across every Renovate PR. Split enforcement:

**Hard fail:** master-helm-repo `helm template` (tenancy/region `fail`), missing `missingkey=error` when `.values.*` is used, `HEAD`/`latest` on CRD-shipping or platform operator charts, multi-region AppSets without region `RollingSync`, `ignoreMissingValueFiles: true` without a documented optional-path list, and CRD compat gates when the pin moves an operator CRD.

**Soft warn:** enablement/app `HEAD`, missing ownership labels, prod/CRD AppSets that stay fully automated with no change-window note, single management topology after scale signals appear, KubeVela shape/pins not recorded.

Promote individual warns to fails per repo once noise is low. Keep operator pins and `missingkey=error` hard from day one.

Details live in [argocd-skill](/public/skills/argocd-appset/SKILL.md)

---

## FAQ

### Why wrap ApplicationSets in a Helm chart?

So env-specific values, shared helpers (`validateRegions`), and CI (`helm template`, schema checks) apply to the *definitions* of your apps the same way they apply to workload charts.

### Is RollingSync required for every AppSet?

No. Single-cluster or non-prod AppSets can sync in parallel. Use RollingSync when a Helm chart bump has multi-region blast radius. Do note that it is a BETA feature at the time of writing.

### How does this relate to KubeVela?

KubeVela composes the workload. Argo CD still delivers it. Use the same AppSet, pins, labels, and sync options. Choose either nested OAM under Helm `values` or a dedicated OAM source path, record which one in the PR, and pin image + traits revisions.

### Should every sync use Server-Side Apply?

Default to SSA for platform/operator charts and CRDs. Know that field-manager conflicts need an explicit migration plan when resources were created with client-side apply.

### Why Delete, recreate or force option can be destructive for CRD's/AppSet's

If you have a crd (Argo app & appsets) and if you delete that crd, k8s will automatically delete all the custom resources for that crd so that means all your applications now get deleted and if they're marked for deletion and the finalizers are set then that means all their resources get deleted too.

Force option (like the kubectl force) will try to patch/update a resource five times and if it fails it will then delete and recreate. So let's say a scenario where the crd's was being upgraded and for some reason it caused conflict that k8s was not able to resolve/patch/upgrade the resource. Eventually, after the fifth attempt it will delete the crd triggering Mass deletion of all the resource managed by CRD & potentially starting a fresh synch of Resources. YES.. Production outage will Follow

### What's the role of Finalizer & how it Impacts Argo application

Resources will be deleted by the Argo controllers if a finalizer is removed and the deletion Time stamp is set in a cascading manner by default. So if you delete an application that has set finalizer for its resources, then the argocd controller will update all of those child resources to add the deletion time Stamp. Once the finalizer is removed kubernetes will actually do the deletion

For example if you deleted any of the controller that's responsible for some finalizer, it is going to be stuck in deletion. So you could have a scenario where you were you were upgrading Argo CD and you deleted some components and those components would then be stuck in deletion because they could not complete the deletion that Argo CD was trying to accomplish because Argo CD's controller is no longer running

### Should every checklist item fail CI?

No. Fail the sharp edges (`missingkey=error`, operator pins, multi-region RollingSync, undocumented `ignoreMissingValueFiles`, CRD gates). Warn on enablement `HEAD`, labels, and similar until the repo is ready to promote them.

### How can I disable AutoSync for all Application in a Argo Instance?

You can temporarily disable auto-sync for all applications in an Argo CD project from the UI by creating a Deny Sync Window in your project settings. Argo CD does not have a single global "pause auto-sync" toggle switch in the project UI, so a temporary deny window is the standard built-in workaround. [Sync Windows](https://argo-cd.readthedocs.io/en/release-2.0/user-guide/sync_windows/)

---

## Reference

- [Argo CD documentation](https://argo-cd.readthedocs.io/en/stable/)
- [Argo project blog](https://blog.argoproj.io/)
- [Tracking strategies](https://argo-cd.readthedocs.io/en/stable/user-guide/tracking_strategies/)
- [Helm user guide](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/) (`valueFiles`, `ignoreMissingValueFiles`)
i- [Progressive Syncs / RollingSync](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Progressive-Syncs/)
- [ApplicationSet UI / label ergonomics](https://blog.argoproj.io/exposing-applicationsets-beyond-yaml-argo-cds-applicationset-ui-a7a45f3054d2)
