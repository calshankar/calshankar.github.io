---
title: KubeVela + OAM ~ The Abstraction Your Dev Team Actually Needs - Part 2
description: Use the Open Application Model (OAM) with KubeVela to wrap Argo Rollouts, AnalysisTemplates, HLA, and ArgoCD ApplicationSets into a single YAML that any developer can ship in under an hour.
sidebar:
  order: 4
---

*By Shankar Ramanathan*

[Part 1](/blogs/progressive-delivery-part1) walked through raw Argo Rollout CRDs, AnalysisTemplates, and the promote-or-abort loop. The manifests work, but they are also 150+ lines of YAML per service, and every team copies, forks, and drifts from what the platform originally intended.

This post covers the layer above: the Open Application Model (OAM) via KubeVela. One YAML file, a handful of reusable traits, and your rollout, analysis, autoscaling, and ingress are declared together — versioned in Git, deployed through ArgoCD, and consistent across every cluster.

## What OAM and KubeVela actually solve

Kubernetes gives you primitives — Deployments, Services, Ingress, HPA, PDB — and expects you to wire them together. OAM replaces that per-resource assembly with two ideas:

- **Components** describe what your workload is (a web server, a rollout, a job).
- **Traits** attach operational capabilities to a component (autoscaling, analysis, environment config) without modifying the component definition.

KubeVela is the platform engine that implements OAM on Kubernetes. You write one `Application` manifest, KubeVela renders the underlying Kubernetes resources, and you never touch an Ingress or HPA directly.

```text
┌─────────────────────────────────────────────────────┐
│                 OAM Application YAML                │
│                                                     │
│  ┌─────────────┐   ┌────────────────────────────┐   │
│  │  Component   │   │         Traits             │   │
│  │  (rollouts)  │──▶│ analysistemplate            │   │
│  │              │   │ hla (PDB + KEDA + lifecycle)│   │
│  │  - image     │   │ envfrom (ConfigMap/Secret)  │   │
│  │  - replicas  │   │ sidecar                    │   │
│  │  - strategy  │   └────────────────────────────┘   │
│  │  - ingress   │                                    │
│  └─────────────┘                                     │
└──────────────────────┬──────────────────────────────┘
                       │ KubeVela renders
                       ▼
┌──────────────────────────────────────────────────────┐
│              Kubernetes Resources                    │
│                                                      │
│  Rollout CRD ──▶ ReplicaSets (stable + canary)       │
│  Service (stable) ◄──┐                               │
│  Service (canary) ◄──┤                               │
│  Ingress         ◄──┤  traffic routing               │
│  AnalysisTemplate    │                               │
│  PodDisruptionBudget │                               │
│  ScaledObject (KEDA) │                               │
│  ServiceMonitor      │                               │
└──────────────────────────────────────────────────────┘
```

The developer writes the top box. The platform team controls what the bottom box produces by maintaining the component and trait definitions in CUE.

## Prerequisites

Before creating OAM manifests or deploying applications, ensure you have:

- **Kubernetes cluster** with KubeVela installed (`vela install`)
- **Container registry** your cluster can pull from
- **CI/CD tooling** — GitHub Actions runners and ArgoCD for build/test/push of OAM manifests
- **CLI tools** — `kubectl`, `helm`, and `vela` CLI (run `vela show <trait> -n vela-system` to explore available parameters)

## Components and traits: the mapping

If you have written raw Kubernetes manifests before, this table maps what you know to OAM concepts:

| Kubernetes Resource | OAM Equivalent | Where It Lives |
|---|---|---|
| Deployment / Rollout CRD | Component (`type: rollouts`) | `spec.components[].properties` |
| HPA + PDB + lifecycle hooks | Trait (`type: hla`) | `spec.components[].traits[]` |
| AnalysisTemplate | Trait (`type: analysistemplate`) | `spec.components[].traits[]` |
| ConfigMap / Secret injection | Trait (`type: envfrom`) | `spec.components[].traits[]` |
| Sidecar containers | Trait (`type: sidecar`) | `spec.components[].traits[]` |
| Ingress | Built into the rollouts component | `spec.components[].properties.ingress` |

You can create custom traits in CUE to encode any organizational pattern. The trait definitions live in a central repo and are installed on every cluster, so teams get guardrails without copy-pasting boilerplate. See the [custom trait development guide](https://kubevela.io/docs/platform-engineers/traits/customize-trait#using-cue-as-trait-schematic) for details.

## Setting up the Rollout component

The `rollouts` component type wraps the Argo Rollout CRD. The key parameters mirror standard Kubernetes Deployment fields:

| Parameter | Description | Default |
|---|---|---|
| `image` | Container image (e.g., `nginx:1.21.0`) | — (required) |
| `replicas` | Desired pod count | `3` |
| `minReadySeconds` | Seconds a pod must be ready before considered available | `30` |
| `revisionHistoryLimit` | Old ReplicaSets retained for rollback | `3` |
| `progressDeadlineSeconds` | Max seconds before a stalled rollout is marked failed | `600` |

Full parameter reference: [Rollouts component spec](https://github.com/calshankar/oam-component-traits/blob/main/docs/documentation/reference_traits/rollouts.md)

The `strategy` block is where Part 1's canary steps live, but now they are nested inside the component properties rather than in a standalone Rollout CRD. The component also handles Ingress creation, ServiceMonitor generation via `prometheusPort`/`prometheusPath`, and stable/canary Service objects.

> **Note:** Argo Rollouts does not duplicate ConfigMaps or Secrets during deployment. Both the stable and canary ReplicaSets share the same ConfigMap/Secret references. [Review the Argo Rollout spec](https://argo-rollouts.readthedocs.io/en/latest/features/specification/) for the full resource lifecycle.

## Canary strategy: from raw CRD to OAM

In Part 1, the canary strategy lived in a standalone `Rollout` YAML. In OAM, it becomes a nested block inside the component `properties.strategy`. The shape is the same — `setWeight`, `pause`, `analysis` steps — but now the Rollout, Services, Ingress, and AnalysisTemplates are co-located in one file.

Here is how the canary steps, background analysis, and traffic routing look inside an OAM Application:

```yaml
strategy:
  type: "Canary"
  canary:
    canaryService: rollouts-poc-canary
    stableService: rollouts-poc-stable
    trafficRouting:
      nginx:
        stableIngress: rollouts-poc-stable
        additionalIngressAnnotations:
          nginx.ingress.kubernetes.io/canary: "true"
    canaryMetadata:
      annotations:
        argorollouts.kubernetes.io/identifier: rollouts-canary
    stableMetadata:
      annotations:
        argorollouts.kubernetes.io/identifier: rollouts-stable
    # Background analysis runs from step 2 onwards
    analysis:
      templates:
        - templateName: success-rate-analysis
      startingStep: 2
      args:
        - name: ingress-name
          value: rollouts-poc-stable
    steps:
      - setWeight: 20
      - pause: { duration: "5m" }
      - setWeight: 40
      - analysis:
          templates:
            - templateName: latency-analysis
          args:
            - name: ingress-name
              value: rollouts-poc-stable
      - setWeight: 60
      - pause: { duration: "3m" }
      - setWeight: 80
      - pause: { duration: "5m" }
```

```text
Traffic flow during canary rollout
──────────────────────────────────

Step 1:  setWeight: 20
         ┌──────────┐      80%      ┌──────────────┐
         │  Ingress  │─────────────▶│ Stable RS    │
         │  (nginx)  │              │ (v1 - blue)  │
         │           │──┐           └──────────────┘
         └──────────┘  │   20%      ┌──────────────┐
                       └──────────▶│ Canary RS    │
                                    │ (v2 - green) │
                                    └──────────────┘

Step 2:  pause: 5m  → background analysis starts (success-rate)

Step 3:  setWeight: 40
         ┌──────────┐      60%      ┌──────────────┐
         │  Ingress  │─────────────▶│ Stable RS    │
         │           │──┐           └──────────────┘
         └──────────┘  │   40%      ┌──────────────┐
                       └──────────▶│ Canary RS    │
                                    └──────────────┘

Step 4:  inline analysis (latency-analysis) → blocks until pass/fail

Step 5-8: 60% → pause 3m → 80% → pause 5m → promote or abort
```

The full working manifest: [test-argo-rollouts-hla-lifecycle.yaml](https://github.com/calshankar/oam-component-traits/blob/main/tests/test_oam_applications/test-argo-rollouts-hla-lifecycle.yaml)

## AnalysisTemplate as a trait

Instead of maintaining separate AnalysisTemplate YAML files, you attach them as traits to the rollout component. The controller creates the AnalysisTemplate resource on the cluster; the rollout strategy references it by `templateName`.

Required parameters:

| Parameter | Description |
|---|---|
| `name` | Unique identifier for the AnalysisTemplate |
| `namespace` | Kubernetes namespace for the template |
| `metrics` | List of metric definitions with provider, query, success/failure conditions |

Optional but useful: `args` for parameterized queries, `dryRunMetricName` to test queries without affecting rollout state, and `templates` for referencing cluster-scoped templates.

Here is a success-rate analysis paired with a latency analysis on the same component:

```yaml
traits:
  - type: analysistemplate
    properties:
      name: success-rate-analysis
      namespace: rollouts-poc
      args:
        - name: ingress-name
      metrics:
        - name: success-rate
          interval: 1m
          successcondition: "result[0] >= 0.95"
          failurelimit: 3
          provider:
            address: http://prometheus-prometheus.monitoring.svc:9090
            query: |
              sum(rate(nginx_ingress_controller_requests{ingress="{{args.ingress-name}}", status!~"[4-5].*"}[2m])) by (ingress) /
              sum(rate(nginx_ingress_controller_requests{ingress="{{args.ingress-name}}"}[2m])) by (ingress)

  - type: analysistemplate
    properties:
      name: latency-analysis
      namespace: rollouts-poc
      args:
        - name: ingress-name
      metrics:
        - name: p99
          interval: 1m
          successcondition: "result[0] <= 5"
          count: 2
          failurelimit: 1
          provider:
            address: http://prometheus-prometheus.monitoring.svc:9090
            query: |
              histogram_quantile(0.99, sum by(le) (rate(nginx_ingress_controller_request_duration_seconds_bucket{ingress=~"{{args.ingress-name}}"}[1m]))) * 1000
```

```text
AnalysisRun lifecycle during canary
───────────────────────────────────

 Rollout step                AnalysisRun                     Prometheus
 ──────────                  ───────────                     ──────────
 setWeight: 20 ──────────▶  background analysis starts
                             │                               
                             ├─ query (t=0) ───────────────▶ success-rate ≥ 0.95? ✓
                             │  wait interval: 1m
                             ├─ query (t=1m) ──────────────▶ success-rate ≥ 0.95? ✓
                             │  wait interval: 1m
                             ├─ query (t=2m) ──────────────▶ success-rate = 0.91? ✗
                             │  failureLimit: 3 (1 of 3 used)
                             ├─ query (t=3m) ──────────────▶ success-rate ≥ 0.95? ✓
                             │  ...continues until count reached
                             │
 setWeight: 40 ──────────▶  inline analysis (latency) starts
                             ├─ query: p99 ≤ 5ms? ✓
                             ├─ query: p99 ≤ 5ms? ✓
                             └─ 2/2 success → proceed
                                                             
 setWeight: 60 ──────────▶  continues...
```

Use `dryRunMetricName` to validate your PromQL against live metrics without gating the rollout. Platform teams can publish `ClusterAnalysisTemplate` objects to standardize queries across namespaces.

Full AnalysisTemplate reference: [analysistemplate spec](https://github.com/calshankar/oam-component-traits/blob/main/docs/documentation/reference_traits/analysistemplate.md)

Combined example with rollout + analysis: [test-argo-rollouts-analysis.yaml](https://github.com/calshankar/oam-component-traits/blob/main/tests/test_oam_applications/test-argo-rollouts-analysis.yaml)

## HLA trait: PDB + KEDA + lifecycle in one block

The `hla` (High-Level Availability) trait bundles three concerns that are usually three separate YAML files:

1. **Pod Disruption Budget** — guarantees a minimum number of pods during node drains or maintenance. Default: `minAvailable: 50%` when replicas > 1.
2. **KEDA autoscaling** — scales pods based on Prometheus metrics, CPU, memory, or external triggers. Supports scaling from zero for dev/QA environments.
3. **Lifecycle hooks** — `preStop` commands to drain connections gracefully before pod termination.

```yaml
- type: hla
  properties:
    pdb:
      type: "maxUnavailable"
      value: 1
    lifecycle:
      containers:
        - name: rollouts-poc
          preStop:
            exec:
              command: ["sleep", "10"]
        - name: nginx-prometheus-exporter
          preStop:
            exec:
              command: ["sleep", "1"]
    keda:
      maxReplicaCount: 5
      triggers:
        - type: "cpu"
          metricType: "Utilization"
          metadata:
            value: "60"
      prometheusTriggers:
        - metricName: "nginx_connections_waiting"
          threshold: "0.25"
          metricType: "AverageValue"
          query: 'sum(rate(nginx_connections_waiting{service="rollouts-poc"}[1m]))'
```

```text
HLA trait: what gets created on the cluster
────────────────────────────────────────────

  hla trait properties
  ┌─────────────────────┐
  │  pdb:               │──▶  PodDisruptionBudget
  │    maxUnavailable: 1│       (max 1 pod down during maintenance)
  │                     │
  │  lifecycle:         │──▶  Pod spec lifecycle hooks
  │    preStop: sleep 10│       (graceful drain before SIGTERM)
  │                     │
  │  keda:              │──▶  ScaledObject (KEDA)
  │    cpu > 60%        │       │
  │    prom metric      │       ├── HPA (auto-created by KEDA)
  │    max: 5 replicas  │       └── Scale 3 → 5 on load
  └─────────────────────┘           Scale 5 → 3 on cooldown
```

Full HLA trait reference: [hla spec](https://github.com/calshankar/oam-component-traits/blob/main/docs/documentation/traits/hla.md)

## Best practices and parameter tuning that prevent real incidents

The sections above cover how each piece works. This section covers how to configure them so they hold up in production. These are grouped by concern — general rollout hygiene, resource management, canary-specific tuning, blue-green specifics, analysis template configuration, and monitoring.

### Getting the rollout foundation right

Before tuning anything strategy-specific, get the basics in place. Skipping any of these creates problems that surface during the rollout rather than before it.

**Always define both `canaryService` and `stableService`.** Without explicit service separation, the controller falls back to replica-weighted traffic splitting. That is a much weaker signal than Ingress-level splitting because it depends on pod counts rather than actual request routing. If you are using `trafficRouting` with nginx, both services are mandatory.

**Start every canary strategy with a short timed pause.** Even `pause: { duration: "10s" }` is enough. Kubernetes needs a moment to propagate pod labels after the canary ReplicaSet is created. Without it, the first analysis sample can hit the wrong pods and produce a false failure (or worse, a false success).

**Set resource requests and limits on every component.** During a canary rollout, you are temporarily running more pods than steady state. If the canary pods have no resource requests, the scheduler might pack them onto an overcommitted node, and the latency spike you see in analysis is infrastructure noise rather than an application problem. Define `cpuRequest`, `memoryRequest`, `cpuLimit`, and `memoryLimit` in the rollout component properties.

**Configure liveness, readiness, and startup probes.** Without readiness probes, the canary Service receives traffic before the application is actually ready. Without liveness probes, a stuck pod stays in rotation and contaminates your canary metrics. Startup probes are particularly important for JVM or heavy-init applications — they prevent the liveness probe from killing a pod that is still loading.

**Write clear comments in your manifest.** OAM collapses many resources into a single file. Six months from now, someone will need to understand why `scaleDownDelaySeconds` is 120 instead of the default 60. A one-line comment next to the value saves a Slack thread.

**Use namespaces deliberately.** Keep the Rollout, its AnalysisTemplates, and the HLA trait in the same namespace. Cross-namespace references for AnalysisTemplates require `ClusterAnalysisTemplate` objects, which are a different resource type entirely.

**Always test in a non-production cluster first.** Run `vela dry-run -f <your-app>.yaml` locally to validate syntax, then deploy to staging. A broken AnalysisTemplate query that returns no data will cause the analysis to hang until `timeout`, not fail fast.

### Resource management during rollouts

Rollouts create additional ReplicaSets, which means additional pods competing for cluster resources. These parameters control how that plays out.

**`minReadySeconds`** controls how long a new pod must be healthy before the controller considers it available. The default in the rollouts component is 30 seconds. If your application takes longer to warm up (loading caches, establishing connection pools), increase this. Setting it too low means the controller advances to the next step while the pod is still cold, and your analysis metrics reflect warm-up latency rather than steady-state behavior.

**`progressDeadlineSeconds`** is your safety net for stalled rollouts. The default is 600 seconds (10 minutes). If no progress happens within this window — pods stuck in `ImagePullBackOff`, crash-looping init containers, a misconfigured readiness probe — the rollout is marked as failed. Set this based on your worst-case deploy time. For applications with heavy database migrations or slow JVM startup, 900-1200 seconds is reasonable.

**`revisionHistoryLimit`** controls how many old ReplicaSets are retained for rollback. The default is 3, which is enough for most services. More than 5 just wastes etcd storage and makes `kubectl get rs` noisy. If your team rarely rolls back beyond the previous version, 2 is fine.

**Monitor resource usage during the rollout itself.** The canary pods share the cluster with stable pods. If you see CPU throttling or memory pressure during the canary window, it might not be a code regression — it might be the cluster running out of headroom because you are now running `replicas * 2` pods temporarily.

### Canary deployment tuning

The canary strategy has several parameters that control rollout speed, safety margins, and traffic behavior.

**`maxSurge` and `maxUnavailable`** work together to balance rollout speed against availability. `maxSurge` is the number of extra pods the controller can create beyond the desired replica count (default: 2). `maxUnavailable` is how many stable pods can be taken down during the update (default: 1). For a conservative rollout, set `maxSurge: 1` and `maxUnavailable: 0` — the controller creates one canary pod at a time and never reduces the stable set below the desired count.

**`scaleDownDelaySeconds`** keeps the old ReplicaSet alive after a weight shift. The default is 60 seconds. This matters because in-flight requests to the stable pods need time to drain. If you serve long-lived WebSocket connections or streaming responses, increase this to 120-300 seconds. For short HTTP request/response cycles, 60 seconds is usually sufficient.

**`minPodsPerReplicaSet`** ensures a minimum number of pods in each ReplicaSet during traffic-routed canaries (default: 1). When your Ingress splits traffic by weight, you need at least one pod on each side to actually serve requests. If your service handles high throughput, increase this so the canary pod set has enough capacity to handle its share of traffic without saturating.

**Shift traffic in gradual steps.** The step sequence `20% → 40% → 60% → 80% → 100%` with pauses between each increment gives you multiple observation windows. Each pause is a chance for analysis to catch a regression. Jumping from 20% straight to 100% saves time but defeats the purpose of canary.

**Define explicit rollback criteria in your analysis templates.** The analysis template's `successCondition` and `failureCondition` are your automated rollback triggers. Vague conditions like `result[0] > 0` are dangerous — they pass even when the metric is suspiciously low. Be specific: `result[0] >= 0.95` for success rate, `result[0] <= 200` for p99 latency in milliseconds.

### Blue-green deployment tuning

Blue-green is the alternative to canary when you want an all-or-nothing traffic switch rather than gradual weight shifting.

**`autoPromotionSeconds`** controls how long the green (preview) environment runs before traffic is switched automatically. For critical services, set this high enough for your monitoring to catch problems — 300-600 seconds is a common range. For lower-risk services in staging, 60-120 seconds keeps iteration fast.

**`previewReplicaCount`** determines how many pods run in the green environment during validation. This does not need to match your production replica count. For validation purposes, 1-2 replicas are often enough. Match production replicas only if your validation includes load testing.

**Configure pod anti-affinity between blue and green.** Using `antiAffinity.preferredDuringSchedulingIgnoredDuringExecution` ensures the preview pods land on different nodes from the active pods. This protects against a scenario where a single node failure takes out both versions and gives you a more realistic assessment of how the green version behaves on production-class hardware.

**Run pre-promotion and post-promotion analysis.** Blue-green supports both `prePromotionAnalysis` (runs before the traffic switch) and `postPromotionAnalysis` (runs after). Pre-promotion catches problems while only preview traffic hits the new version. Post-promotion catches issues that only appear under full production load. Use both when the risk warrants it.

**Validate end-to-end before promotion.** Automated analysis alone may not catch UI regressions, broken integrations, or data consistency issues. Include smoke tests or synthetic transaction checks in your pre-promotion window.

### Analysis template configuration

The analysis template parameters directly control how sensitive your automated gates are. Too strict and every deploy gets aborted. Too loose and bad code ships.

**`interval` and `count`** together define the observation window. An interval of `1m` with a count of `5` means the analysis runs for at least 5 minutes. Match this to how quickly your application's metrics stabilize. Stateless API services stabilize in 2-3 minutes. Services with connection pools, caches, or downstream warmup may need 5-10 minutes.

**`successCondition` and `failureCondition`** should be specific and meaningful. For success rate, `result[0] >= 0.95` is a common threshold. For latency, express the condition in the same unit your query returns — if the query returns milliseconds, write `result[0] <= 200`, not `result[0] <= 0.2`. A mismatch here is one of the most common debugging time-sinks.

**`consecutiveSuccessLimit`** requires multiple passing measurements in a row before the analysis is considered successful. This reduces the risk of promoting on a single lucky sample. A value of 3 means three consecutive measurements must pass. This is especially useful for metrics with high variance, like p99 latency.

**`initialDelay`** delays the first measurement after the analysis run starts. The default in the trait is 3 minutes. Applications need warmup time — JVM JIT compilation, connection pool establishment, cache hydration. Measuring p99 latency during the first 60 seconds of a JVM service's life produces numbers that have nothing to do with steady-state performance.

**Tune based on observed behavior.** After a few rollouts, review the analysis run results. If you see intermittent failures followed by recovery, increase `failureLimit` from the default 3 to 4-5. If the analysis consistently passes on the first measurement, you can reduce the `count` to shorten the rollout window. These numbers are not set-and-forget.

### Monitoring and metric query hygiene

**Use `dryRunMetricName` during initial setup.** This runs the Prometheus query and records the result, but the outcome does not affect the rollout. Use it for your first 2-3 deployments with a new analysis template to verify the query returns sensible numbers. Once you trust the query, remove the metric name from the dry-run list and let it gate the rollout for real.

**Set `timeout` on metric queries.** If Prometheus is slow or unreachable, the analysis run blocks until timeout. Without an explicit timeout, the rollout sits in a `Running` state indefinitely. A timeout of 30-60 seconds is usually appropriate — if Prometheus cannot respond in that window, something else is wrong.

**Write PromQL queries that return meaningful results even under low traffic.** The classic failure mode: your success-rate query divides requests with `status!~"[4-5].*"` by total requests. If total requests are zero (off-hours, low-traffic service), you get `NaN`, which fails the `successCondition`. Guard against this with a `or vector(1)` fallback, or use `failureCondition` instead of `successCondition` so that `NaN` does not auto-fail the analysis.

**Review and update metrics periodically.** Application behavior drifts over time — new endpoints, changed latency profiles, different traffic patterns. A query that was accurate six months ago may no longer reflect actual service health. Schedule a quarterly review of your analysis templates alongside your SLO review.

**Set up alerts for analysis run failures.** When a rollout aborts, the team should know immediately — not discover it the next morning when the dashboard shows the old version is still running. Pipe analysis run status into your alerting system via the Argo Rollouts notification controller or ArgoCD notifications.

## Deploying with ArgoCD ApplicationSet

The recommended path: package your OAM Application as a Helm chart, then deploy it across clusters using an ArgoCD `ApplicationSet`.

```text
Deployment flow: Git → ArgoCD → KubeVela → Kubernetes
─────────────────────────────────────────────────────

┌─────────────────────┐     ┌──────────────────────┐
│  Git Ops Repository │     │  Helm Chart Repo     │
│                     │     │  (App-specific)      │
│  ApplicationSet     │     │                      │
│  manifest           │────▶│  charts/oam-app/     │
│                     │ ref │  ├── Chart.yaml      │
└─────────────────────┘     │  ├── values.yaml     │
                            │  └── templates/      │
                            │      └── application │
                            │         .yaml (OAM)  │
                            └──────────┬───────────┘
                                       │
                    ArgoCD syncs       │
                    ┌──────────────────▼───────────────────┐
                    │         ArgoCD ApplicationSet        │
                    │                                      │
                    │  generator: clusters / git           │
                    │  ┌────────┐ ┌────────┐ ┌────────┐   │
                    │  │ App    │ │ App    │ │ App    │   │
                    │  │ (eu)   │ │ (us)   │ │ (apac) │   │
                    │  └───┬────┘ └───┬────┘ └───┬────┘   │
                    └──────┼──────────┼──────────┼────────┘
                           │          │          │
                    ┌──────▼──────────▼──────────▼────────┐
                    │         KubeVela Controller          │
                    │  Renders OAM → K8s resources         │
                    │                                      │
                    │  Rollout + Services + Ingress         │
                    │  + AnalysisTemplates + PDB + KEDA     │
                    └──────────────────────────────────────┘
```

### Repository layout

```text
Git Ops Repository
├── ApplicationSet definition          ◄── points to Helm chart repo

Helm Chart Repository (app-specific)
└── charts/oam-app/
    ├── Chart.yaml
    ├── rollouts-poc-app-values.yaml
    └── templates/
        ├── application.yaml           ◄── OAM Application manifest
        └── _helpers.tpl
```

**Step 1:** Create the OAM Application in your Helm chart repo. Version the chart per environment. Example: [test-argo-rollouts-hla-lifecycle.yaml](https://github.com/calshankar/oam-component-traits/blob/main/tests/test_oam_applications/test-argo-rollouts-hla-lifecycle.yaml)

**Step 2:** Create the ApplicationSet manifest in your GitOps repo, pointing to the Helm chart. The ApplicationSet uses cluster generators to target multiple clusters. Example: [sampleAppSet.yaml](https://github.com/calshankar/oam-component-traits/blob/main/argoManifest/sampleAppSet.yaml)

The ApplicationSet supports both cluster-selector generators (deploy to every cluster matching a label) and git-file generators (read per-environment values from a git repo). The `syncPolicy` should use `ServerSideApply=true` for KubeVela CRDs.

## Watch out: accidental deletions during rapid syncs

KubeVela is safe under normal use, but back-to-back manual syncs in ArgoCD can trick the garbage collector into deleting running resources. The GC sees the current application as outdated while the next sync is already in flight.

Two mitigations:

1. **Use auto-sync** instead of manual sync in production. Auto-sync serializes reconciliation.
2. **Enable the `garbage-collect` policy** in your KubeVela Application to retain legacy resources during updates. See [KubeVela GC policy docs](https://kubevela.io/docs/v1.9/end-user/policies/gc/).

## Pre-deploy checklist

A quick-reference list before you ship. Each item maps back to the detailed guidance in the [best practices section](#best-practices-and-parameter-tuning-that-prevent-real-incidents) above.

- [ ] Both `canaryService` and `stableService` defined in the strategy
- [ ] First canary step is a timed `pause` (minimum 10s) for label propagation
- [ ] `cpuRequest`, `memoryRequest`, `cpuLimit`, `memoryLimit` set on the rollout component
- [ ] Liveness, readiness, and startup probes configured
- [ ] `minReadySeconds` matches your application's warmup time
- [ ] `progressDeadlineSeconds` set high enough for worst-case deploy duration
- [ ] `revisionHistoryLimit` set to 3 (or 2 if you rarely rollback beyond previous)
- [ ] `scaleDownDelaySeconds` ≥ 60s (higher for WebSocket or streaming workloads)
- [ ] Analysis template `initialDelay` accounts for application warmup
- [ ] `successCondition` units match the query's return units (ms vs seconds)
- [ ] `dryRunMetricName` used for first 2-3 deploys with a new analysis template
- [ ] `timeout` set on metric queries to avoid indefinite blocking
- [ ] PromQL queries handle zero-traffic scenarios (no `NaN` failures)
- [ ] `syncPolicy` uses `ServerSideApply=true` for KubeVela CRDs in ApplicationSet
- [ ] Tested in staging with `vela dry-run -f <app>.yaml` before production

## References

- [OAM Application examples (Argo Rollouts + Analysis Templates)](https://github.com/calshankar/oam-component-traits/tree/main/tests/test_oam_applications)
- [Rollouts component reference](https://github.com/calshankar/oam-component-traits/blob/main/docs/documentation/reference_traits/rollouts.md)
- [AnalysisTemplate trait reference](https://github.com/calshankar/oam-component-traits/blob/main/docs/documentation/reference_traits/analysistemplate.md)
- [HLA trait reference](https://github.com/calshankar/oam-component-traits/blob/main/docs/documentation/reference_traits/hla.md)
- [KubeVela garbage collection](https://kubevela.io/docs/v1.9/end-user/policies/gc/)
- [Vela CLI reference](https://kubevela.io/docs/cli/vela/) — `vela show <component-or-trait> -n vela-system` lists configurable parameters
- [Part 1: Argo Rollouts + AnalysisTemplates](/blogs/progressive-delivery-part1)
