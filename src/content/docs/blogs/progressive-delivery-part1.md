---
title: Argo Rollouts + AnalysisTemplates ~ Release with Confidence - Part1
description: Replace a Kubernetes Deployment with an Argo Rollout CRD, shift traffic in steps, and let Analysis steps decide promote vs abort.
sidebar:
  order: 3
---

*By Shankar Ramanathan*

Kubernetes Deployments give you rolling updates and not much else. If a bad image ships, you find out after traffic is already on it, and rollbacks are a separate scramble.

Argo Rollouts replaces the Deployment object with a CRD that can shift traffic in steps, pause for approval or metric checks, and abort back to the old ReplicaSet when Prometheus (or another provider) says the canary is unhealthy. This post walks through the Rollout + AnalysisTemplate model with working manifests.

## Why a Deployment isn't progressive delivery

A Deployment creates a new ReplicaSet, ramps pods, and drains the old set. Traffic usually follows pod readiness. There is no built-in "send 20% of requests to the new version, check error rate, then decide."

That gap is what progressive delivery fills. You want:

* Gradual traffic weight changes (not only pod counts)
* Automatic promote, pause, or abort from metrics
* A clean path back to the previous ReplicaSet when the canary fails

Argo Rollouts does that by owning ReplicaSets the way a Deployment does, then adding a declarative `strategy` (canary, blue-green) plus optional AnalysisRuns. You can keep the manifests in Git and apply them with Argo CD like any other CRD. Ingress controllers and Gateway API plugins handle the weight shifts when you need true traffic splitting instead of replica-only canaries.

```text
  Git / Argo CD
        │
        ▼
  Rollout CRD ──► ReplicaSets (stable + canary)
        │                │
        │                ▼
        │         Service / Ingress / Gateway
        │                │  (traffic weight)
        ▼                ▼
  AnalysisRun ◄── Prometheus (or Job / plugin)
        │
        └── success → next step
            failure → abort, canary weight → 0
            inconclusive → pause
```

## What your app must already support

Rollouts will not fix an app that cannot tolerate two versions at once.

* The service must run multiple versions concurrently (no single-writer assumptions that break under canary).
* Avoid shared locks or exclusive resources that only one version can hold.
* Prometheus (or another supported provider) should be reachable from the cluster.
* Promotion metrics must be trustworthy. Garbage SLIs produce confident wrong aborts, or worse, confident wrong promotes.

If those are false, fix the app or the metrics first. The controller cannot invent safe canaries for you.

## Replace Deployment with a Rollout CRD

Create a `Rollout` instead of a `Deployment`. The pod template looks familiar. The difference is `spec.strategy`: canary steps that set weight, pause, and optionally start analysis.

I still trip over `pause: {}`. An empty pause waits until someone promotes via CLI or UI. A timed pause (`pause: {duration: 10}`) continues on its own. Mixing those up is how you end up staring at a "Paused" rollout that is doing exactly what you asked.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: rollout-background-analysis
spec:
  replicas: 4
  revisionHistoryLimit: 2
  selector:
    matchLabels:
      app: rollout-background-analysis
  template:
    metadata:
      labels:
        app: rollout-background-analysis
    spec:
      containers:
      - name: rollouts-demo
        image: argoproj/rollouts-demo:blue
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
          name: http
          protocol: TCP
        resources:
          requests:
            cpu: 5m
            memory: 32Mi
  strategy:
    canary:
      maxSurge: "25%"
      maxUnavailable: 0
      steps:
      # Send 20% of traffic to the canary, then wait for a human or automation to promote.
      - setWeight: 20
      - pause: {}
      # Start an AnalysisRun from the named template before taking more traffic.
      - analysis:
          templates:
          - templateName: success-rate
      - setWeight: 50
      - pause: {duration: 10}
      - setWeight: 100
```

Any change to `spec.template` starts a new revision. The controller creates the canary ReplicaSet and walks the steps. Without a traffic provider, `setWeight` mostly shapes relative replica counts. With Ingress or Gateway API integration, weights map to real request splitting.

Blue-green and experiment-backed steps are available too. For Part 1, canary + analysis is the path that teaches the model fastest.

## How AnalysisTemplates decide promote vs abort

An `AnalysisTemplate` declares how to measure the canary. At runtime the controller creates an `AnalysisRun`, which blocks the step until the run finishes.

Outcomes that matter:

* **Success** → continue to the next step
* **Failure** → abort the update and set canary weight to zero
* **Inconclusive** → pause for a human decision

You choose the queries, intervals, and thresholds. Examples that hold up in production reviews:

* **Error rate:** fewer than 5% of requests are errors → success; otherwise fail the canary
* **Request rate:** sustained traffic stays at or above ~100 rps during the window → success; a collapse under ~20 rps → fail (low traffic is not a healthy canary signal)
* **Latency:** p95 of successful requests under 200ms → success; otherwise fail
* **Success rate:** at least 95% of requests succeed → success; otherwise fail

Composite failure rules are common:

* Error rate rises by 10% relative to baseline, **or** request rate falls under 20 rps → fail
* More than 5% errors, **or** request duration rises by more than 40% → fail

Here is a namespace-scoped template that checks success rate via nginx Ingress Controller metrics. Pass the ingress name as an argument from the Rollout.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
spec:
  args:
  - name: ingress
  metrics:
  - name: success-rate
    # Wait for the canary to see traffic before the first sample.
    initialDelay: 2m
    interval: 3m
    count: 6
    # Prometheus returns a vector; take the first sample.
    successCondition: result[0] >= 0.95
    failureLimit: 2
    provider:
      prometheus:
        address: http://prometheus-prometheus.monitoring.svc:9090
        query: |
          sum(rate(nginx_ingress_controller_requests{ingress="{{args.ingress}}",status!~"[45].*"}[5m]))
          /
          sum(rate(nginx_ingress_controller_requests{ingress="{{args.ingress}}"}[5m]))
```

Wire the argument from the Rollout analysis step:

```yaml
- analysis:
    templates:
    - templateName: success-rate
    args:
    - name: ingress
      value: rollout-background-analysis
```

Notes that save debugging time:

* Validate the PromQL in the Prometheus UI before you trust an AnalysisRun.
* `failureLimit: 2` allows two failed measurements before the run fails. Pair with `count` and `interval` so the total window matches how long you are willing to burn on a bad canary (here: about 18 minutes after the initial delay).
* Dry-run analysis exists when you want to exercise templates against live metrics without promoting.

Templates can hold multiple metrics. Parameterize them and reuse across services. Platform teams often publish cluster-scoped `ClusterAnalysisTemplate` objects as a golden path so every namespace does not invent its own success-rate query.

## Soak tests without committing production traffic

An `Experiment` is a separate CRD for running baseline and canary workloads (and analysis) without rewriting the main Rollout strategy. Use it when you need a long soak, memory-leak hunt, or A/B comparison before you are ready to put production weight on the new version.

Rollouts can start experiments from canary steps, optionally with partial traffic and a backing Service, Ingress, or Gateway. That is different from a plain `analysis` step: experiments are the "study this build for a while" tool; analysis steps are the "gate this traffic shift" tool.

## Trade-offs: Rollouts vs the alternatives

**Stay on Deployment** if you only need rolling updates and are fine discovering bad releases from alerts after the fact. Less moving parts. Weaker delivery controls.

**Feature flags** still win for per-request or per-tenant exposure inside the app. Rollouts operate at ReplicaSet and traffic-weight granularity. Many teams use both: Rollouts for binary/image risk, flags for behavioral risk.

**Flagger** is the usual alternative in the same progressive-delivery niche. Flagger often wraps an existing Deployment and drives canaries via its own CRDs. Argo Rollouts replaces the Deployment with a Rollout and sits naturally next to Argo CD. Pick based on which control plane you already run and whether you want Deployment-compatible wrapping or an explicit Rollout object. I prefer Rollouts when GitOps already centers on Argo CD and I want analysis templates as first-class YAML beside the app.

**Limitations to respect:**

* No trustworthy metrics → automated promote/abort is theater
* Apps that cannot run two versions → canary is unsafe regardless of controller
* Traffic splitting needs a supported mesh, Ingress, or Gateway plugin; replica-only canaries are a weaker signal
* `pause: {}` without a clear promotion owner will stall pipelines

## Features

Some of the additional feature (not explored here) but worth mentioning here

* [x] Allows for Manual Approval gate
* [x] Observe Ongoing rollout via Rollout UI & promote release as well
* [x] Dry-run mode to test the Rollout Analysis, Analysis Template with Metrics without promotion
* [x] Supports experiment CRD for long running tests to compare the performance metrics while both baseline and canary are running

## Try it

1. Install Argo Rollouts in a non-prod cluster ([getting started](https://argo-rollouts.readthedocs.io/en/stable/getting-started/)).
2. Deploy the [official rollouts-demo](https://github.com/argoproj/rollouts-demo) image or the [sample manifests with AnalysisTemplate references](https://github.com/calshankar/argo-rollouts-demo).
3. Watch a revision hit `setWeight: 20`, sit on `pause: {}`, then either promote (`kubectl argo rollouts promote <name>`) or let analysis abort on a bad metric.

Further reading:

* [Migrating Deployments to Rollouts](https://argo-rollouts.readthedocs.io/en/stable/migrating/#migrating-to-rollouts)
* [Canary step plugins](https://argo-rollouts.readthedocs.io/en/stable/features/canary/plugins/)
* [Progressive delivery with Gateway API](https://rollouts-plugin-trafficrouter-gatewayapi.readthedocs.io/en/latest/)
* [Experiments CRD for launching Ephemeral Analysis](https://argo-rollouts.readthedocs.io/en/stable/features/experiment/)

The Part 2 will cover, how to abstract all concepts into simple YAML format for Developers get the Rollouts / Release experiments running in under 60mins.
