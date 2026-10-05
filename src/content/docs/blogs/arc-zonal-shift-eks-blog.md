---
title: ARC zonal shift on Amazon EKS
description: ARC zonal shift on Amazon EKS moves traffic off an impaired Availability Zone in minutes but requires preparatory steps, design consideration, failure modes for EKS data plane and Karpenter to successfully execute one.
sidebar:
  order: 1
---

**By Shankar Ramanathan**

Glossary:
- ICE - Insufficient capacity error
- ODCR - On-Demand Capacity Reservations

ARC zonal shift on Amazon EKS moves traffic off an impaired Availability Zone in minutes. It does not magically create capacity in the zones that remain. If your workloads, HPA targets, and Karpenter NodePools were sized for three healthy AZs, a shift leaves you fighting a race: traffic arrives in the healthy zones before pods and nodes catch up.

This guide is for platform and SRE teams who already run Karpenter, HPA and other platform controllers on EKS, and now need to enable ARC zonal shift without pretending the rest of the stack will “just work.” I’ll cover what EKS and Karpenter do natively, a concrete enable-and-test path, how topology and stateful PVCs behave under a shift, an honest take on two capacity patterns (low-priority On-Demand placeholders and ODCR-backed NodePools), and how the Kubernetes Descheduler can fix the AZ skew that stays behind after the shift ends.

>[!WARNING]
> "This post is 700+ line long because everything is connected or that is what I thought 😂. I refuse to leave you with half a puzzle. Consider this your official invitation to stretch your legs, refill your coffee/snacks, and prepare for a deep dive."

## Who this is for

You already have:

- An EKS cluster spanning at least two AZs (three is safer)
- Karpenter v1.12+ on a system node group
- Horizontal Pod Autoscalers on application workloads
- Argo CD (and optionally Argo Events) for GitOps
- Controllers for AWS capacity or related infra

You want a manual or autoshift path that on-call can run and practice, not a greenfield redesign.

## What ARC zonal shift solves on EKS (and what it does not)

[Amazon Application Recovery Controller (ARC) zonal shift](https://docs.aws.amazon.com/r53recovery/latest/dg/arc-zonal-shift.html) temporarily steers traffic for a supported resource away from one AZ in a Region. Shifts expire (one minute to 72 hours) and can be canceled. [Zonal autoshift](https://docs.aws.amazon.com/r53recovery/latest/dg/arc-zonal-autoshift.html) lets AWS start that shift when AZ telemetry looks bad, and requires weekly practice runs.

For EKS specifically, enabling zonal shift on the cluster registers it with ARC. When a shift is active, EKS:

1. Cordons nodes in the impaired AZ so the scheduler stops placing new pods there
2. Removes pod endpoints in that AZ from EndpointSlices so east-west and service traffic stay in healthy AZs
3. Leaves existing pods on impaired-AZ nodes running (so capacity can return when the shift ends)
4. Adjusts compute behavior based on how you provision nodes (Auto Mode, managed node groups, or Karpenter)

AWS is explicit about the hard requirement: **prescale**. If you are not already able to run with one AZ gone, starting a shift can make the outage worse. There is a fail-safe that can keep sending traffic to impaired-AZ endpoints when a workload has *no* healthy endpoints left. Treat that as a last resort, not a design.

Zonal shift does **not do**:

- Scale your Deployments for you
- Guarantee EC2 capacity in the remaining AZs during a regional scramble
- Move or remount EBS volumes across AZs
- Rebalance pods after the shift ends (Kubernetes will not evict healthy pods just to restore topology skew)

## How the pieces interact when a shift starts

```text
                    ┌─────────────────────────────────────┐
                    │  ARC zonal shift / autoshift         │
                    │  away-from: AZ ID (e.g. use1-az5)    │
                    └──────────────┬──────────────────────┘
                                   │
           ┌───────────────────────┼───────────────────────┐
           ▼                       ▼                       ▼
   EKS data plane           Karpenter (v1.12+)      ALB / NLB (optional
   • Cordon impaired AZ     • No new nodes in       ARC registration)
   • EndpointSlice trim       impaired AZ           • Targets only healthy AZs
   • Leave pods in place    • Block voluntary
                              disruption that
                              depends on that AZ
                                   │
                                   ▼
                         Pending pods need room in
                         healthy AZs: HPA / KEDA

                         Design Pattern:
                         placeholders (preempt) /
                         ODCR-backed NodePools /
                         Argo Events (your choice)
```

Two layers have to agree:

1. **Traffic** leaves the impaired AZ (EKS networking + optional ELB zonal shift)
2. **Compute** stops growing that AZ and can grow elsewhere (Karpenter with zonal shift enabled)

Your jobs are capacity math, topology constraints that do not deadlock during a shift, and an on-call practice loop.

## Enable zonal shift on a cluster that already has Karpenter

You need three things. Miss the first and Karpenter will refuse to start cleanly once zonal shift is turned on in the controller.

### 1. Register the EKS cluster with ARC

```bash
aws eks update-cluster-config \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --zonal-shift-config enabled=true
```

Or with eksctl:

```bash
eksctl utils update-zonal-shift-config \
  --cluster="${CLUSTER_NAME}" \
  --enable-zonal-shift=true
```

Enabling the cluster flag is necessary but not sufficient for autoshift. Autoshift and practice runs are configured in ARC after the cluster is registered. See [Enable EKS zonal shift](https://docs.aws.amazon.com/eks/latest/userguide/zone-shift-enable.html).

### 2. Give Karpenter read access to zonal shift status

Karpenter v1.12+ needs `arc-zonal-shift` Get and List permission on the cluster’s ARC resource, plus `eks:DescribeCluster` (most Karpenter IAM setups already have DescribeCluster).

```json
{
  "Sid": "KarpenterZonalShift",
  "Effect": "Allow",
  "Resource": "*",
  "Action": [
    "arc-zonal-shift:GetManagedResource",
    "arc-zonal-shift:ListManagedResources",
    "arc-zonal-shift:ListZonalShifts"
  ],
  "Condition": {
    "StringEquals": {
      "arc-zonal-shift:ResourceIdentifier": "arn:aws:eks:<region>:<account-id>:cluster/<cluster-name>"
    }
  }
}
```

You do **not** need a custom Lambda to cordon nodes. EKS does that when the shift is active. Karpenter watches the managed resource and stops provisioning in the shifted AZ.

### 3. Turn on Karpenter’s zonal shift setting

This is a top-level setting, not a feature gate:

```bash
helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --reuse-values \
  --set "settings.enableZonalShift=true"
```

Equivalent env: `ENABLE_ZONAL_SHIFT=true` on the controller Deployment.

Confirm NodePools still allow multiple AZs in `requirements` so healthy zones remain valid launch targets.

## Start a manual shift (use AZ IDs, not names)

ARC expects Availability Zone **IDs** (`use1-az5`), not names (`us-east-1f`).

```bash
aws ec2 describe-availability-zones \
  --region "${AWS_REGION}" \
  --query 'AvailabilityZones[].{Name:ZoneName,Id:ZoneId}' \
  --output table
```

```bash
aws arc-zonal-shift start-zonal-shift \
  --resource-identifier "arn:aws:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster/${CLUSTER_NAME}" \
  --away-from use1-az5 \
  --expires-in "30m" \
  --comment "Practice: validate Karpenter and topology under zonal shift" \
  --region "${AWS_REGION}"
```

**NOTE**: You must provide the AZ ID ( use1-az5), not the name ( us-east-1f)

Wait at least ~60 seconds between shift operations. EKS polls zonal state; rapid flip-flops can be processed incorrectly.

While the shift is active, scale something that forces new capacity:

```bash
kubectl scale deployment/zonal-shift-demo --replicas=12
kubectl get pods -o wide -l app=zonal-shift-demo
kubectl get nodeclaims -o wide
```

You should see new NodeClaims only in healthy AZs. Nodes already in the shifted AZ stay up; Karpenter will not consolidate or drift them away while the shift depends on that AZ. Cancel or let the shift expire when you are done.

```yaml
Important Note: *Pods do not rebalance by themselves after zonal-shift*. A rollout restart (or the next deploy / Karpenter consolidation after the AZ is healthy again) is what spreads them back.
```

## Topology spread is the footgun: DoNotSchedule vs ScheduleAnyway

I ran a small demo on a 2-AZ cluster (EKS 1.33, Karpenter v1.12.1, Spot NodePool across both AZs) with six nginx replicas and `maxSkew: 1`.

**Baseline with DoNotSchedule:** 3 pods in each AZ.

**During shift, scale 6 → 12 with `whenUnsatisfiable: DoNotSchedule`:**

| AZ | Pods | Notes |
|---|---|---|
| healthy | 4 | 3 original + 1 new |
| shifted | 3 | Original pods untouched |
| (pending) | 5 Pending | Next placement would break maxSkew |

Karpenter launched a node only in the healthy AZ. The scheduler placed one extra pod (skew still 1), then stopped. DoNotSchedule means “prefer fewer Ready pods over breaking spread.” **During an AZ failure, that is reduced capacity**.

**Same scale with `ScheduleAnyway`:**

| AZ | Pods |
|---|---|
| healthy | 12 |
| shifted | 0 (or originals still present until a rolling update moves them; traffic no longer targets them) |

All new capacity landed in the healthy AZ. Nothing Pending for topology reasons.

Patch for the demo:

```bash
kubectl patch deployment zonal-shift-demo --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/topologySpreadConstraints/0/whenUnsatisfiable","value":"ScheduleAnyway"}]'
```

| Constraint | During AZ failure | Sensible default for |
|---|---|---|
| `ScheduleAnyway` | Prefer full availability in healthy AZs | Stateless APIs, web tiers |
| `DoNotSchedule` | May leave pods Pending to protect skew | Workloads where uneven zone placement is worse than losing replicas |
| none | Scheduler places freely | Simple apps with other HA mechanisms |

AWS’s own EKS zonal shift guidance uses `ScheduleAnyway` in the CoreDNS and sample workload examples. For most production APIs on this stack, that is the right default. Stateful workloads with zone-bound volumes need a different plan.

## Stateful workloads and PVCs do not follow the traffic

ARC and EKS move *network endpoints* away from the impaired AZ. They do not move *data*.

What actually happens when a shift starts:

1. Nodes in the shifted AZ are cordoned. New pods will not schedule there.
2. Existing pods, including StatefulSet members and anything sitting on an EBS PVC, **keep running**. EKS does not drain them for you.
3. Those pods lose Service / EndpointSlice membership for in-cluster traffic, so callers in healthy AZs stop sending them work.
4. Karpenter will **not** launch replacement nodes in the shifted AZ for pods that have a hard requirement on that zone (volume topology, required node affinity, or strict `DoNotSchedule` spread that only the shifted AZ can satisfy).

EBS volumes are AZ-scoped. A PVC bound to `us-east-1f` cannot attach to a node in `us-east-1b`. That is an EC2/EBS rule, not something ARC can waive.

| Workload shape | During zonal shift | What to design instead of “ARC will save it” |
|---|---|---|
| Deployment + emptyDir / no PVC | New replicas can land in healthy AZs if topology allows | `ScheduleAnyway` + N-1 replica count |
| Deployment + EBS PVC (unusual) | Pod in shifted AZ stays up but is unreachable via Service; reschedule elsewhere fails attach | Prefer EFS/S3 or replicate data; treat EBS+Deployment as single-AZ |
| StatefulSet + EBS PVC per ordinal | Ordinals pinned to the shifted AZ stay up locally, leave the Service, cannot recreate on another AZ | Quorum / HA at the app layer (multi-AZ replicas with their own volumes), or accept reduced quorum |
| Storage on EFS / S3 / managed DB outside the AZ | Compute can move; data path stays | Prefer this for anything you expect to survive AZ loss |

**Disruption expectations:** Do not wait for a drain. Cordoning alone does not evict. If you manually drain impaired-AZ nodes during a shift, StatefulSet pods with EBS PVCs will Pending until the volume’s AZ is healthy again (or until you restore from backup onto a new volume in a healthy AZ). Practice that failure mode before you script it.

### Platform example: Prometheus Operator

kube-prometheus-stack (and similar) usually runs Prometheus as a StatefulSet with an EBS (or local) PVC per replica. Under a shift:

- The replica in the shifted AZ keeps scraping locally if it can still reach targets on its node network path, but **cluster Services stop advertising it** to queriers in healthy AZs.
- Thanos Sidecar / remote write that depends on that replica’s WAL may stall for that shard.
- Scaling Prometheus up does not recreate the lost shard’s PVC in another AZ.

Practical pattern for platform monitoring under N-1 AZ:

- Run **at least two** Prometheus replicas (or shards) with topology spread and volumes in **different** AZs, sized so one replica’s loss is acceptable for scrape continuity.
- Prefer remote write (Amazon Managed Service for Prometheus, Thanos Receive, Cortex/Mimir) so durable metrics are not trapped on a single EBS volume.
- Keep Alertmanager and Grafana on Deployments with `ScheduleAnyway` (or externalize them) so the paging path is not PVC-bound.
- Do not set `DoNotSchedule` zone spread on Prometheus if losing Ready scrape capacity during a shift is worse than temporary skew.

ARC does not replicate Prometheus TSDB. Your HA story is replica count + remote storage, not zonal shift.

## Prescale first; then decide how aggressive reactive scaling can be

The race is real. Traffic can leave an AZ faster than you can launch EC2, pull images, and pass readiness. Static stability is still the capacity floor AWS asks for. Two common Karpenter patterns try to approximate it cheaper. Both are useful. Neither is magic. One popular weight trick is simply wrong.

### Static stability (preferred when cost allows)

Run three AZs. Size so any two can take 100% of peak. Each AZ runs with spare headroom instead of “exactly one third.” When ARC shifts AZ-A away, B and C absorb load without waiting on Karpenter. ICE(insufficient capacity error) becomes someone else’s problem.

This matches AWS’s “provision enough compute to withstand removal of a single AZ” guidance in the [EKS zonal shift docs](https://docs.aws.amazon.com/eks/latest/userguide/zone-shift.html).

Options A and B below change *latency* and *launch insurance*. They do not erase the N-1 spreadsheet.

### Option A: Low-priority pods occupying an On-Demand NodePool before the shift

**Idea:** Keep pause/placeholder pods on a dedicated On-Demand NodePool in every AZ. When critical work scales up during a shift, the scheduler preempts placeholders and binds onto already-Ready nodes. Karpenter replaces the buffer afterward.

**When it works**

- You need **warm kubelets and warm node capacity** in healthy AZs so HPA/KEDA scale-up is not waiting on EC2 + node join.
- Placeholders are pinned to On-Demand (not Spot) and sized from real N-1 math.
- Critical pods use a higher `PriorityClass` so preemption actually fires.

**When it fails under zonal shift**

- **Traffic still moves before capacity.** Preemption helps pods that can land on *existing* healthy-AZ nodes. It does nothing for EndpointSlice trim latency or for pods that still need *new* nodes after the buffer is consumed.
- **Replacement launches can ICE.** After preemption, Karpenter tries to recreate placeholder (or surge) capacity. That RunInstances call is ordinary On-Demand unless you also have ODCR. Warm buffer ≠ reserved capacity.
- **Consolidation eats the buffer.** Karpenter may disrupt “empty-looking” placeholder nodes unless disruption budgets / full requests stop it.
- **PDBs do not protect placeholders from preemption.** Scheduler preemption is not the Eviction API. A tight PDB on pause pods is the wrong tool; a tight PDB on *apps* can still block later drains/consolidation on healthy AZs.
- **Spot buffer is a non-starter** for this pattern. Spot disappears in the same regional scramble you are practicing for.
- **Stateful / EBS pods** in the shifted AZ still cannot move. Option A only helps schedulable, non-volume-pinned work.

Sketch (buffer pods; pin them to a dedicated pool with a taint):

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: zonal-placeholder
value: -10
globalDefault: false
description: "Evictable On-Demand capacity holders for N-1 headroom"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: az-capacity-placeholders
spec:
  replicas: 12  # from N-1 math
  selector:
    matchLabels:
      app: az-capacity-placeholders
  template:
    metadata:
      labels:
        app: az-capacity-placeholders
    spec:
      priorityClassName: zonal-placeholder
      tolerations:
        - key: capacity-purpose
          operator: Equal
          value: n1-buffer
          effect: NoSchedule
      nodeSelector:
        capacity-purpose: n1-buffer
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: az-capacity-placeholders
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          resources:
            requests:
              cpu: "1"
              memory: 2Gi
```

**Verdict on A:** Keep it as a **latency** tool (warm seats). Do not sell it as ICE(insufficient capacity error) insurance. Pay On-Demand for idle buffer on purpose, or skip A and accept cold starts.

### Option B: ODCR NodePool with `reserved` + `on-demand` and *lower* weight than general

**Idea:** Buy ODCR. Create a NodePool with capacity types `reserved` and `on-demand` only.

#### Why Karpenter Weight is a wrong choice for Multiple Node pools

Karpenter’s docs are explicit ([NodePools](https://karpenter.sh/docs/concepts/nodepools/)): prefer **mutually exclusive** NodePools. If a pod matches multiple pools, Karpenter picks the **highest** weight. Weight is a preference among eligible pools, not a cloud-provider failure circuit breaker.

What actually happens with “general (spot+Ondemand) Node pool weight 100, odcr(reserved+on-demand) Node Pool weight 10” when the same pods can bind to both:

1. Peacetime and shift scale-up prefer **general**.
2. ICE is cached per **offering** (instance type + zone + capacity type), on the order of minutes, not “try the other NodePool now.”
3. Karpenter may churn NodeClaims on the preferred pool’s remaining offerings before (or instead of) cleanly moving demand to the low-weight pool. Fallback across pools is neither guaranteed nor fast; maintainers have documented delayed / surprising behavior here.
4. Your ODCR can sit **unused while pods Pending**, which is the expensive failure mode: you pay for unused reservation *and* still miss the surge.
5. Giving the ODCR pool `reserved` + `on-demand` does not mean “reserved last.” **Inside** a pool, Karpenter prioritizes `reserved` → `spot` → `on-demand`. Lower pool weight keeps you out of that pool; it does not reorder capacity types after ICE on another pool.

Also: if general Node pool includes Spot, Spot evaporates under regional pressure and you burn On-Demand on general before the low-weight ODCR pool is ever interesting. That is more Pending time, not clever cost control.

#### Exclusive pools, not weight-as-ICE-fallback

Karpenter also prioritizes `reserved` first **inside** a single NodePool. So putting `reserved` + `spot` + `on-demand` on one shared pool does the *opposite* of “ODCR only in emergency”: it burns reserved capacity in peacetime whenever a pending pod fits.

Use **mutual exclusion** (taints / nodeSelectors), not weight tricks:

| Pool | Capacity types | Types | Who may schedule | Job |
|---|---|---|---|---|
| `general` | `spot`, `on-demand` | Broad families | Default apps | Cheap diversified compute |
| `n1-buffer` (Option A) | `on-demand` only | Shapes you want warm | Placeholders only (taint) | Warm seats for preemption |
| `n1-odcr` (Option B fixed) | `reserved`, then `on-demand` | **ODCR-matched** shapes only | Critical surge only (taint) | Launch insurance under ICE |

```yaml
# EC2NodeClass that discovers ODCRs (tag per AZ reservations identically)
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: odcr-n1
spec:
  # amiSelectorTerms, subnetSelectorTerms, securityGroupSelectorTerms ...
  capacityReservationSelectorTerms:
    - tags:
        purpose: zonal-n1
        karpenter.sh/discovery: "${CLUSTER_NAME}"
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: general
spec:
  # weight only matters if pods match multiple pools; keep pools exclusive instead
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: topology.kubernetes.io/zone
          operator: In
          values: ["us-east-1b", "us-east-1c", "us-east-1d"]
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: n1-buffer
spec:
  limits:
    cpu: "64"
  template:
    metadata:
      labels:
        capacity-purpose: n1-buffer
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      taints:
        - key: capacity-purpose
          value: n1-buffer
          effect: NoSchedule
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["m6i.xlarge", "m6i.2xlarge"]
        - key: topology.kubernetes.io/zone
          operator: In
          values: ["us-east-1b", "us-east-1c", "us-east-1d"]
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: n1-odcr
spec:
  limits:
    cpu: "128"
  template:
    metadata:
      labels:
        capacity-purpose: n1-odcr
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: odcr-n1
      taints:
        - key: capacity-purpose
          value: n1-odcr
          effect: NoSchedule
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["reserved", "on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["m6i.xlarge", "m6i.2xlarge"]  # must match ODCR purchases
        - key: topology.kubernetes.io/zone
          operator: In
          values: ["us-east-1b", "us-east-1c", "us-east-1d"]
```

#### Why `general` is not enough: two extra pools, two different jobs

`general` is the everyday pool. Broad instance families, Spot plus On-Demand, no special taint. That is where almost every Deployment should live in peacetime.

It cannot do two things you need when an AZ disappears:

1. **Warm seats.** A pending pod on `general` often waits on `RunInstances`, node join, and image pull. During a shift, traffic has already left the impaired AZ. Waiting on cold EC2 is the race you lose.
2. **Launch insurance.** When healthy AZs are also competing for the same instance types, `RunInstances` on `general` returns ICE. Spot on `general` is even worse in that scramble. ODCR is the only mechanism here that makes a specific shape in a specific AZ launchable.

Those are different failure modes, so they get different pools.

**`n1-buffer` (Option A)** exists so On-Demand nodes are already Ready in every AZ, occupied by low-priority pause pods. When higher-priority work needs CPU, the scheduler *preempts* those pause pods and binds onto kubelets that are already up. You pay idle On-Demand for that speed. This pool does not hold an EC2 capacity reservation.

**`n1-odcr` (Option B fixed)** exists so a *new* NodeClaim can still launch when `general` is hitting ICE. Nodes here consume tagged ODCRs (`reserved`, then On-Demand fallback on the same shapes). You pay unused-reservation billing for that insurance. This pool does not keep kubelets warm in advance.

Do not merge them into one extra pool. If the buffer NodePool also selects `reserved`, Karpenter prefers reserved first and burns ODCR on pause pods. If the ODCR pool is also the placeholder home, you either keep expensive reserved nodes full of pause containers (waste) or you have no warm seats when you need preemption (latency). Separate taints keep pause pods off ODCR and keep random apps off both.

Choices: Ideally, you can skip either extra pool. Skip `n1-buffer` if you accept cold node starts. Skip `n1-odcr` if you accept ICE. Skip both if static N-1 replica counts already fit on `general` with headroom.

#### Workloads do not “select buffer, then ODCR”

A single Pod does not fall through `n1-buffer` and then `n1-odcr`. Kubernetes scheduling is not a NodePool chain. Karpenter only considers NodePools the pod is *allowed* to land on (tolerations + selectors + requirements).

The sequence people mean is an **event sequence during the shift**, not a per-pod affinity list:

1. Pause pods already occupy `n1-buffer` nodes in every AZ.
2. Traffic shifts. HPA (or you) raise replica counts. Those **app pods still target `general`** unless you explicitly opt a critical subset into ODCR.
3. If a `general` node is full, the scheduler can **preempt** pause pods (lower `PriorityClass`) and place the app pod on a **Ready `n1-buffer` node**. That only works if the *app* pod also tolerates the buffer taint. If it does not, buffer nodes are invisible to it, and you only get preemption among pods that share those nodes (the pause pods themselves).
4. If you still need *new* EC2 because the buffer is exhausted or the app cannot use buffer nodes, **only pods that select `n1-odcr`** can consume reserved capacity. Everyone else keeps Pending on `general` through ICE.

So: placeholders select buffer. A small critical set selects ODCR. Default apps stay on `general`. Buffer helps those default/critical pods only if you also give *them* the buffer toleration (and usually not a buffer `nodeSelector`, so they still prefer `general` when there is room).

#### Which Deployment uses which pool (selector vs toleration)

Use **both** a `NoSchedule` taint on the extra pools and a required affinity on pods that *belong* there.

| If you only set… | What can go wrong |
|---|---|
| Taint + toleration, no selector | Any pod that copies the toleration (or uses `Exists` on that key) can land on buffer/ODCR and burn the insurance. |
| Selector, no taint | Untainted `general` nodes/Node Pools also have no `capacity-purpose` label, so the selector keeps accidental guests off extra pools. But pods *without* the selector can still schedule onto extra-pool nodes if those nodes are untainted. Taint is what keeps the default app off `n1-buffer` / `n1-odcr`. |
| Neither | Karpenter treats the pools as overlapping. Highest weight wins. ODCR and warm nodes get used as a random extra `general`. |

**Default apps, workloads that can wait on cold nodes, batch:** no extra tolerations, no `capacity-purpose` selector. They only match `general`.

**Placeholder pods only:** selector **and** toleration for `n1-buffer`, plus the low `PriorityClass` shown earlier. Nothing else should use this pair.

**Default apps that should steal warm seats during a shift:** tolerate `n1-buffer` but **do not** nodeSelect it. They stay schedulable on `general`. When `general` is packed, preemption can place them on buffer nodes. They must have a **higher** PriorityClass than `zonal-placeholder`.

```yaml
# Do not put both buffer and ODCR selectors on one pod (one capacity-purpose value).
# Do not give one pod toleration for both extra pools without a selector

apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
spec:
  template:
    spec:
      priorityClassName: production-high  # must beat zonal-placeholder
      tolerations:
        - key: capacity-purpose
          operator: Equal
          value: n1-buffer                # or n1-odcr (not both) for Consuming the Reserved capacity
          effect: NoSchedule
      # no nodeSelector for capacity-purpose: still prefers general
      containers:
        - name: api
          image: example/checkout:1.2
```

**Critical surge that must launch under ICE:** selector **and** toleration for `n1-odcr`. These are the Deployments you cannot leave Pending ( Workloads already sized for N-1, that must reconcile during the incident). Two ways to attach that pair:

- **Always-on.** The Deployment always selects `n1-odcr`. You will consume some reservation in peacetime. Unused ODCR that no workload can select is wasted money.

 The ₹ Workload that tolerates General + n1-odcr in advance`only works as ICE insurance if you also pin with **nodeSelector/affinity** on **capacity-purpose=n1-odcr** (or an equivalent exclusive constraint).` Toleration alone is not enough`.

- **Shift-gated option.** Peacetime spec matches `general` only. On `Manual Shift Started` / `Autoshift In Progress` / practice-run, a practiced Argo Events (or similar) patch adds the `n1-odcr` selector and toleration. If that patch is untested, the pool stays idle while the app Pendings, which is the failure mode Option B’s weight trick also produced.

Once again, Do not put both `n1-buffer` and `n1-odcr` selectors on the same workload. A pod can only require one `capacity-purpose` value. If a critical app should use warm seats *and* reserved launches, split the replica set (most replicas: `general` + buffer toleration; a floor of replicas: `n1-odcr`) or keep ODCR always-on for that Deployment and let buffer serve everyone else.

#### What happens to each pool when the shift starts

Assume three AZs, shift away from AZ-A, apps sized too tight on `DoNotSchedule` or simply short of Ready replicas in Zones B and C.

1. **EKS** cordons AZ-A nodes and drops AZ-A endpoints from EndpointSlices. Pods in A keep running but stop getting Service traffic. HPA sees less healthy capacity or higher load on B/C and wants more replicas.
2. **`general`.** New pods try Spot/On-Demand in B and C. If those AZs still have node room, you are set. If not, Karpenter launches. Under regional pressure this is where ICE and Spot interrupts show up. This pool is not “bad”; it is just unprotected.
3. **`n1-buffer`.** Pause pods in B and C are still Ready. Higher-priority app pods that *tolerate* the buffer taint can preempt them and bind immediately. East-west traffic to those new Ready pods can start without waiting on EC2. Karpenter then tries to recreate pause pods (more On-Demand in B/C). Remember that replacement can still ICE. Buffer bought you **minutes of scheduling latency**, not a guaranteed extra instance.
4. **`n1-odcr`.** Nothing happens unless some pending pod matches this pool i.e **both** toleration + `nodeSelector/affinity`. Critical Deployments with the ODCR selector get NodeClaims that target the reservation in B and C (the A-AZ reservation sits unused, which you already paid for). Those pods become Ready after node join, slower than preemption, but they can succeed when `general` cannot launch. Apps that never got the selector never see this pool.

After the shift ends, EKS uncordons Zone A. `Rebalance onto A is still your job`. Buffer pause pods should refill n A when they can schedule again. ODCR in A becomes usable again for the next event.

### ODCR facts that must know (zonal, not regional)

[ODCRs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html) are **AZ-scoped**. There is no Regional ODCR. Regional RIs / Savings Plans discount bills; they do not reserve capacity. Unknown impaired AZ ⇒ buy the N-1 share **in each AZ**; pay for idle insurance in the AZ that is not absorbing the surge.

Prefer **targeted** matching for the critical pool so random Auto Scaling / unmanaged launches do not steal the reservation. Select reservations on the EC2NodeClass (`capacityReservationSelectorTerms`). With native Karpenter ODCR support.

Docs: [EC2 Capacity Reservations](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html), [Karpenter ODCR](https://karpenter.sh/docs/tasks/odcrs/), [NodePools (weight / mutual exclusion)](https://karpenter.sh/docs/concepts/nodepools/).

**Stack verdict:** Static N-1 math first. Option A for warm seats. Option B only as an **exclusive**, taint-gated ODCR pool that critical pods can actually select, not as a lower-weight ICE afterthought. Diversified `general` handles everyone else.

### Other Noteworthy Options: Event-driven pod scale-up (optional)

Ideally, to be uses to raise HPA floors or notify on-call when a shift starts. ARC emits EventBridge events with source `aws.arc-zonal-shift`. Useful `detail-type` values include:

- `Manual Shift Started` / `Manual Shift Canceled`
- `Autoshift In Progress` / `Autoshift Completed`
- `Practice Run Started` / `Succeeded` / `Failed` / `Interrupted`

Patterns and examples: [Using zonal autoshift with EventBridge](https://docs.aws.amazon.com/r53recovery/latest/dg/eventbridge-zonal-autoshift.html).

On a cluster that already has HPA, Argo CD, and Crossplane, sensible patterns look like this:

| Pattern | What it does | Trade-off |
|---|---|---|
| EventBridge → CloudWatch metric → KEDA | Bump `minReplicaCount` when a shift metric flips | Simple; CloudWatch + poll latency; no in-cluster API mutation from AWS |
| EventBridge → SQS → KEDA | Faster queue-length signal than metrics | Still pod-only; needs queue hygiene when the shift ends |
| EventBridge → SQS/SNS → Argo Events Sensor | Patch HPA / Deployment inside the cluster; keeps GitOps boundaries | More moving parts; Sensors must reconcile with Argo CD ownership |

Prefer one of the event pattern approach or Argo Events (or a documented sync wave / ApplicationSet override) over out-of-band approach (patching live objects will fight GitOps) so the desired state and the emergency patch share one ownership model. You might need to use the `ignoreDifferences` [feature in ArgoCD](https://argo-cd.readthedocs.io/en/release-1.8/user-guide/diffing/#application-level-configuration) to skip specific fields.

Event-driven scale-up works best when placeholders or ODCRs already removed the cold EC2 wait. Scaling pods into a Pending queue during ICE only moves the outage into `kubectl get pods`.

>[!TIP]
>Argo as of Release 3.4.1+ Argo supports pausing [cluster reconciliations](https://argo-cd.readthedocs.io/en/release-3.4/operator-manual/declarative-setup/#skipping-cluster-reconciliation) by adding the annotation argocd.argoproj.io/skip-reconcile: "true" in the cluster secret

## What EKS and Karpenter do when the shift ends

When the shift expires or is canceled:

- EKS removes cordons / restores EndpointSlices for the AZ
- Karpenter resumes normal provisioning and voluntary disruption
- Workloads gradually return as pods recycle; they do not snap back to even skew

The recovered AZ comes back empty of *your* steady-state pods unless something creates new ones there. HPA churn can slowly refill it. Deployments pinned at a stable replica count stay skewed until you restart them, or until something like the Descheduler evicts the extras in the overloaded zones.

Plan the rebalance on purpose: Descheduler for soft topology drift (below), a targeted rollout restart for critical Deployments, or accept skew until the next deploy. Switching topology constraints mid-incident without a restart will confuse you during post-incident review.

## How Descheduler fixes the AZ skew a zonal shift leaves behind
>[!NOTE]
>De-scheduler  make sense only if substantial fraction of your workload is in violation of Topology constraint set and sustained skew is observed after the Zonal Shift end. Usually ~ 20-25% of skew auto corrects over-time.

[Descheduler](https://github.com/kubernetes-sigs/descheduler/blob/release-1.36/README.md#removepodsviolatingtopologyspreadconstraint) aims to address the same failure mode you hit after a shift: soft `topologySpreadConstraints` (`whenUnsatisfiable: ScheduleAnyway`) let the scheduler pack surviving zones during a node-availability gap, then **nothing in core Kubernetes moves running pods** once capacity returns. The workloads can hold the skew for hours together with every node healthy again in the shifted AZ. Workloads that keep churning recover by accident. Workloads at steady state keep the shape the gap gave them.

When the shift ends, the impaired AZ uncordons, but the pods that piled into the other zones stay put. Your manifests still claim `maxSkew: 1`. The running fleet does not.

### The plugin that matters for AZ rebalance

The Descheduler does not place pods. It runs on a periodic loop, evaluates a policy, **evicts** violators through the Eviction API (so PDBs apply), and lets kube-scheduler place the replacements.

For topology / AZ drift, the relevant plugin is `RemovePodsViolatingTopologySpreadConstraint`. Defaults only act on hard constraints (`DoNotSchedule`). Most production APIs on this stack use soft spread, so you must list `ScheduleAnyway` in the plugin’s `constraints` or the Descheduler will ignore the skew you care about:

```yaml
deschedulerPolicy:
  maxNoOfPodsToEvictPerNamespace: 5  # volume cap per run; tune to namespace size
  profiles:
    - name: rebalance-topology
      pluginConfig:
        - name: RemovePodsViolatingTopologySpreadConstraint
          args:
            constraints:
              - DoNotSchedule
              - ScheduleAnyway  # required for soft spread used during zonal shift
            namespaces:
              include:
                - apps  # start with narrow target
            topologyBalanceNodeFit: true  # skip eviction if no better node exists
        - name: DefaultEvictor
          args:
            evictSystemCriticalPods: false  # leave system-critical priority alone
            evictLocalStoragePods: false    # skip emptyDir / local-storage pods
            ignorePvcPods: true             # skip PVC-backed pods (StatefulSet + EBS)
            nodeFit: true
            priorityThreshold:
              value: 10000                  # do not evict at or above this priority
      plugins:
        balance:
          enabled:
            - RemovePodsViolatingTopologySpreadConstraint
```

`topologyBalanceNodeFit: true` (plugin arg) and `nodeFit: true` (DefaultEvictor) are the safety rails that refuse an eviction when the only domain that would fix skew is still unschedulable. In the AWS measurement, while one AZ stayed cordoned, the Descheduler logged “ignoring pod for eviction as it does not fit on any other node” and skipped the pods whose only legal destination was that zone.

Do **not** enable `LowNodeUtilization` (or similar consolidation plugins) next to the topology plugin on day one. One spreads pods across zones; the other packs them onto fewer nodes. Together they can oscillate, and on a Karpenter cluster that already consolidates, you get competing movers, which essentially means more 🎇 🧨

### Tradeoffs

| Approach | What you get | What you pay |
|---|---|---|
| Manual `kubectl rollout restart` per Deployment | Predictable, human-gated | Operational toil at fleet scale; easy to miss namespaces; big blast radius if you restart everything at once |
| Descheduler + soft spread + PDBs | Continuous correction toward `maxSkew`; PDB-throttled concurrency; `maxNoOfPodsToEvictPerNamespace` caps volume per run | Every correction is a pod restart (connections drop, caches cold); slow-starting apps widen the unready window; PDBs limit concurrency, they do not remove disruption |
| Hard `DoNotSchedule` only | Skew never forms | During the next shift you may Pending pods instead of serving; that is a different outage shape |

Descheduler also interacts with Karpenter. Evictions free nodes in overloaded AZs and create Pending pods that prefer the underloaded AZ. Karpenter may launch there, then later consolidate elsewhere. That is useful after a shift, and noisy if both controllers thrash. Keep eviction caps modest, keep PDBs sized for N-1, and treat Descheduler as a balance tool, not a substitute for static stability.

Trial & error excercise is required to get the setting right since many pods may not scale as fast you expect. Scale `maxNoOfPodsToEvictPerNamespace` down and PDB headroom up until practice runs look boring.

## Keep Descheduler from acting during an active zonal shift

You do **not** want topology rebalance while ARC is still steering traffic off an AZ. Healthy zones are already absorbing load. Extra evictions there buy you restarts in the middle of the incident, and some “rebalance among survivors” work is useless once the third AZ returns.

Descheduler is setup as CronJob in suspended mode after zonal shift. If you need live Descheduler metrics,  the recommended mode is Deployment.

| Control | How | Honest limit |
|---|---|---|
| **Suspend the CronJob** | `kubectl -n kube-system patch cronjob descheduler -p '{"spec":{"suspend":true}}'` (or Helm `--set suspend=true`). AWS’s operating guidance: pause during planned capacity drains and cluster upgrades. Same idea for an active shift. | Best on/off switch for CronJob installs. You must unsuspend after the shift, or skew never heals. |
| **EventBridge → suspend / unsuspend** | On `Manual Shift Started` / `Autoshift In Progress` / `Practice Run Started`, suspend. On `Manual Shift Canceled` / `Autoshift Completed` / practice terminal events, unsuspend (optionally after a short soak so the AZ is schedulable). Wire the same ARC EventBridge patterns you already use for HPA floors. | The descheduler post does not ship this wiring. You compose ARC events with CronJob suspend. Test the unsuspend path; a stuck `suspend: true` is a silent config bug. |
| **`topologyBalanceNodeFit: true` + `nodeFit: true`** | Skips evictions when no better Ready, schedulable node exists (cordoned / full / affinity-blocked). | Necessary safety, **not** a full pause. In AWS’s cordoned-zone pass, the Descheduler still evict pods that *could* fit among surviving zones. During a real shift that means it can still disrupt healthy-AZ capacity. |
| **Cron schedule only** | Longer intervals (`*/15` or more in production). Quiet/Off peak hour schedules sound safe. | Quiet hours are often `minReplicas`, where percentage PDBs are weakest and skew has an arithmetic floor. Schedule alone does not know about ARC. |
| **Namespace / label scope** | `namespaces.include` on the topology plugin; DefaultEvictor `labelSelector` / `namespaceLabelSelector`. | Shrinks blast radius. Does not stop in-scope apps from being evicted mid-shift. |

What does **not** work as a shift gate:

- Hoping soft spread “waits until the AZ is back.” Soft spread only scores *new* pods.
- Relying on PDBs alone. PDBs throttle concurrent disruption; they do not know you are in an ARC event.
- Expecting Karpenter’s zonal-shift awareness to pause Descheduler. Karpenter stops provisioning / voluntary disruption in the shifted AZ. Descheduler is a separate controller.

Practical default on this stack: CronJob Descheduler with `topologyBalanceNodeFit: true`, **suspended for the whole active shift** via the same EventBridge → Argo Events (or equivalent) path you use for scale-up, then unsuspended after cancel/expiry once nodes in the recovered AZ are Ready and unschedulable is clear.

## Permanently keep Descheduler off certain workloads

Some pods should never be part of topology rebalance. Prometheus (or any StatefulSet on EBS), singletons, and anything that cannot restart cheaply belong on the deny list. The Descheduler `DefaultEvictor` policy setting ignores rebalancing but it is not a magic wand.

Also scope with `namespaces.include` / `namespaces.exclude` on `RemovePodsViolatingTopologySpreadConstraint` so that any critical namespaces never enter the balance plugin.

For a **specific** Pod or Pod template that still matches your policy, Descheduler supports two annotations. Read them carefully; they are not mirrors of each other:

| Annotation | Effect |
|---|---|
| `descheduler.alpha.kubernetes.io/prefer-no-eviction` | Pod prefers not to be evicted. Honored as a hard exclude only when DefaultEvictor sets `noEvictionPolicy: Mandatory` (default policy treats it as preferred). |
| `descheduler.alpha.kubernetes.io/evict` | **Opt-in / override**, not a disable switch. Presence makes the pod eligible and bypasses several internal “do not evict” checks. Do **not** set `evict: "false"` expecting protection; any value is treated as eligible. |

Good exclude candidates on an ARC-enabled cluster:

- Prometheus / Thanos / any StatefulSet with EBS (zone-bound; eviction cannot create capacity in another AZ)
- In-cluster databases and queue leaders that lose quorum on restart
- Low-replica Deployments where a percentage PDB rounds up and one eviction is half the fleet (use absolute PDB values below ~10 replicas, or exclude them)

Descheduler is for restartable, multi-replica, soft-spread apps. It is not how you “move” an EBS-backed workloads (For Ex: Prometheus shard) after a shift. That still needs the data-plane HA pattern in the stateful section above.

## Practice runs are the real operational control

Manual demos prove Karpenter respects the shift. Autoshift practice runs prove the *application* survives one missing AZ under something closer to production traffic.

Weekly practice runs are required for zonal autoshift. Wire EventBridge notifications for `Practice Run Failed` and `Practice Run Interrupted` to the same channel on-call already trusts. Measure:

1. Time from shift start to healthy EndpointSlice view
2. Time to Ready replicas at your “N-1 AZ” floor
3. Whether Karpenter launched only in healthy AZs
4. Whether CoreDNS / platform controllers stayed Ready (spread and scale them like apps)
5. Whether Platform and Application workloads control planes lost quorum or Pending on PVC attach
6. Whether placeholder preemption and/or ODCR-backed NodeClaims covered the surge without ICE
7. Whether Descheduler stayed suspended for the active shift, then restored per-AZ skew afterward without evicting PVC / prefer-no-eviction workloads

You can also validate with AWS FIS using `aws:arc:start-zonal-autoshift` if you want chaos tooling instead of a console click.

## Known limitations (read these before you enable autoshift)

- **Not pre-scaled?** Expect delayed recovery and possible ICE. AWS says this plainly. Placeholders and ODCRs are tools for that plan, not a substitute for writing the N-1 numbers down.
- **No Regional ODCR:** Capacity Reservations are AZ-scoped. Regional RIs / Savings Plans discount bills; they do not reserve EC2 capacity. Unknown impaired AZ ⇒ ODCR in each AZ for the N-1 share.
- **Single shared pool with `reserved` + Spot/On-Demand:** Karpenter tries `reserved` first inside a pool, so peacetime traffic can burn ODCR. Opposite of “emergency only.”
- **Option A without ODCR:** Warm seats; replacement launches can still ICE.
- **Stateful / zone-bound volumes:** ARC will not move EBS. Pods that must attach in the shifted AZ stay there (unreachable via Service) or Pending if you bounce them. Design HA in the data layer (see stateful section above).
- **PDBs vs traffic shift:** Keep the PDB sized for **N-1 AZ**, not for “all replicas forever.” Prefer `maxUnavailable` (count or percentage) over a `minAvailable` that assumes three healthy AZs. A PDB does not restore EndpointSlice membership or Service traffic to an impaired AZ. Oversized `minAvailable` can block healthy-AZ drains and consolidation after the shift. Preemption ignores PDBs.
- **Pods do not chain NodePools:** There is no “try `n1-buffer` then `n1-odcr`” on one spec. Placeholders select buffer. Critical ICE-sensitive Deployments select ODCR. Default apps stay on `general`; give them a buffer *toleration* (not a buffer selector) only if they should steal warm seats via preemption.
- **EKS Fargate:** Zonal shift does not work the same way; Fargate has its own AZ preference behavior.
- **Self-managed Karpenter below v1.12:** No native zonal shift integration. Upgrade first.
- **ODCR without NodeClass selection:** With native Karpenter ODCR support enabled, open reservations are not magically consumed; they must appear in `capacityReservationSelectorTerms`, and some exclusive NodePool must allow `karpenter.sh/capacity-type: reserved`.
- **ALB/NLB:** Register load balancers with ARC separately if north-south traffic must also leave the AZ; cluster shift alone does not replace ELB zonal shift for every ingress pattern.
- **Interdependent apps without pod affinity:** Spreading unrelated tiers across AZs without colocating call chains can turn one AZ loss into an end-to-end outage even if each Deployment has replicas elsewhere.
- **Descheduler during an active shift:** Ideally `topologyBalanceNodeFit` skips moves into a cordoned AZ, but can still evict among healthy zones. Suspend the CronJob for the shift; unsuspend after recovery. PVC / prefer-no-eviction workloads stay out of scope.

## Checklist before the first production practice run

- [ ] `zonalShiftConfig.enabled` on the EKS cluster
- [ ] Karpenter ≥ 1.12 with `settings.enableZonalShift=true`
- [ ] IAM: `arc-zonal-shift:GetManagedResource` (+ `eks:DescribeCluster`) on the Karpenter controller role
- [ ] Split **mutually exclusive** NodePools: `general` (broad Spot/On-Demand) + optional `n1-buffer` (placeholders) + optional `n1-odcr` (taint-gated `reserved`/`on-demand`); do **not** use lower weight as ICE fallback
- [ ] Workload map written down: placeholders = buffer selector+toleration; default apps = `general` only (optional buffer *toleration* for preemption, no buffer selector); ICE-critical = ODCR selector+toleration (always-on or practiced shift patch). Extra pools use taint **and** selector.
- [ ] Critical Deployments (and CoreDNS) use multi-AZ spread with `ScheduleAnyway` unless you have a documented reason not to
- [ ] Stateful / PVC workloads (Prometheus, in-cluster DBs, Airflow metadata) have an explicit N-1 data plan
- [ ] Capacity plan for N-1 AZ documented: static replicas and/or Option A buffer and/or **ODCR counts in each AZ** with a path that actually selects `n1-odcr`
- [ ] If using ODCR: tagged reservations per AZ, EC2NodeClass selectors, targeted matching preferred; critical pods tolerate `n1-odcr` always or via practiced shift-gated patch
- [ ] PDBs sized for N-1 (prefer `maxUnavailable`); placeholders without a blocking PDB; no assumption that PDB restores shifted traffic
- [ ] EventBridge alerts for practice / autoshift outcomes (optional)
- [ ] Argo CD ownership rules for any emergency HPA or ODCR-toleration patches (optional)
- [ ] Rebalance procedure after shift ends: **Check descheduler action is warranted**, Descheduler (soft spread + `ScheduleAnyway` in plugin constraints) and/or targeted rollout restart, sized so PDBs do not deadlock the drain
- [ ] If using Descheduler : CronJob suspend for active ARC shifts; `topologyBalanceNodeFit: true` + `nodeFit: true`; `ignorePvcPods: true`; exclude volume backed workloads (namespace and/or `descheduler.alpha.kubernetes.io/prefer-no-eviction` with `noEvictionPolicy: Mandatory`)
- [ ] Do not pair topology Descheduler with `LowNodeUtilization` until PDBs and Karpenter consolidation behavior are proven stable

## Try this next

1. Enable cluster + Karpenter zonal shift using the commands above (official walkthrough: [Karpenter Getting Started: Zonal Shift Onboarding](https://karpenter.sh/v1.12/getting-started/getting-started-with-karpenter/#zonal-shift-onboarding-optional)).
2. Run one **manual** 30-minute shift in a non-prod cluster and scale a Deployment with both `DoNotSchedule` and `ScheduleAnyway` so your team sees the Pending-pod failure mode firsthand.
3. During the same practice window, bounce a PVC-backed Prometheus (or similar) pod in the shifted AZ and watch it Pending on volume topology. Decide whether remote write / multi-AZ replicas are enough before you enable autoshift.
4. If you use Option A / Option B, verify under a practice shift: placeholders preempt; `n1-odcr` NodeClaims show `capacity-type=reserved` for critical pods that tolerate the taint; ODCR is not sitting unused while general churns ICE. Docs: [Karpenter ODCR](https://karpenter.sh/docs/tasks/odcrs/), [EC2 Capacity Reservations](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html), [NodePools](https://karpenter.sh/docs/concepts/nodepools/).
5. Drain one healthy-AZ node during a practice shift and confirm PDBs still allow eviction at N-1 replica counts. If drain blocks, loosen `minAvailable` / switch to `maxUnavailable` before autoshift.
6. After the practice shift ends, leave one soft-spread Deployment skewed on purpose, then run a suspended-CronJob Descheduler pass (`RemovePodsViolatingTopologySpreadConstraint` with `ScheduleAnyway`) and confirm it converges without touching PVC / prefer-no-eviction workloads.
7. Read [Learn about ARC zonal shift in Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/zone-shift.html) end to end, understand the exact controller behaviors then configure a practice run before you turn on autoshift.

If the practice run fails because you ran out of Ready pods in healthy AZs, that is the feature working as designed. Fix capacity and topology before you let AWS autoshift production for you.
