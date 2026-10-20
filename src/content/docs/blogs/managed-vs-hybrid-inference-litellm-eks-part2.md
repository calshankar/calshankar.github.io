---
title: Stop Renting GPUs You Do Not Fill Part2 - Enterprise Governance with RBAC, Kyverno Model Whitelisting, and Bedrock Inference Profiles
description: Governing gen-AI platform - Routing Multi-Provider Inference with LiteLLM, Kyverno, Crossplane on EKS
sidebar:
  order: 6
---
*By Shankar Ramanathan*

In [Part 1 of this series](./managed-vs-hybrid-inference-litellm-eks-part1.md), we established the unit economics of LLM inference, the financial tipping point between managed Bedrock serverless APIs and dedicated GPU nodes, and the multi-tier routing architecture.

Now in Part 2, we implement the complete governance and enforcement engine inside Amazon EKS.

When multiple application pods share an AI gateway, governance cannot rely on trust. Without automated policy enforcement, a runaway agent loop or an unoptimized batch job can consume millions of tokens in minutes, running up substantial unplanned cloud spend.

Governing a multi-tenant generative AI platform on Amazon EKS requires coordinating four distinct enforcement tiers:

1. **Cluster Admission Control (Kyverno)**: Restricts namespace capabilities, validates pod security profiles, and binds client identities strictly to allowed model lists.
2. **AI Gateway Policy & Runtime Enforcement (LiteLLM)**: Enforces API key authorization, team spend allocations, rate limits, and sub-millisecond circuit breaking.
3. **Bedrock Application Inference Profiles**: Isolates AWS account quotas, provides cost-allocation tags for the AWS Cost and Usage Report (CUR), and prevents noisy-neighbor throttling across business units.
4. **Declarative In-Cluster Circuit Breaking via Model Route Mutation**: Crossplane observes live CloudWatch metric alarms in Kubernetes as `MetricAlarm` custom resources. When an alarm triggers, Kyverno detects the status update (`status.atProvider.stateValue`), extracts the breached team name, and dynamically mutates LiteLLM's configuration to swap that team's virtual model alias to an explicit error route. LiteLLM watches its configuration file, hot-reloads in memory with zero container restarts, and drops subsequent prompts with an informative HTTP 429 response.

```mermaid
flowchart TD
    subgraph EKSCluster["Amazon EKS Governance Plane"]
        ClientPod["Client Microservice Pod<br/>(Team: team-alpha)"]
        KyvernoPolicy["Kyverno Policy Engine<br/>(dynamic-team-inference-circuit-breaker)"]
        BaseConfig["ConfigMap: litellm-base-config<br/>(/etc/litellm/base.yaml)"]
        RouteConfig["ConfigMap: litellm-team-routes<br/>(/etc/litellm/routes/team-alpha.yaml)"]
        LiteLLMGW["LiteLLM AI Gateway Pod<br/>(LITELLM_WATCH_CONFIG: True)"]
        CrossplaneCW["Crossplane AWS CloudWatch Provider<br/>(team-alpha-token-alarm)"]

        ClientPod -.->|"1. Manifest Admission Check"| KyvernoPolicy
        ClientPod -->|"2. POST /v1/chat/completions<br/>model: team-alpha-bedrock-profile"| LiteLLMGW
        LiteLLMGW <-->|"3. Directory Watcher on /etc/litellm/routes"| RouteConfig
        LiteLLMGW <-->|"4. Base Gateway Config"| BaseConfig
    end

    subgraph AWSManagement["AWS Provider & Observability Plane"]
        AppProfile["Bedrock Application Inference Profile<br/>(team-alpha-aip)"]
        BedrockFM["Amazon Bedrock Foundation Model<br/>(Nova Pro / Claude 3.5 Sonnet)"]
        BedrockLogs["Bedrock Invocation Logs<br/>(/aws/bedrock/invocation-logs)"]
        CWFilter["CloudWatch Metric Filter<br/>(TeamId Dimension)"]
        CWAlarm["CloudWatch Rolling Alarms<br/>(Bedrock-TokenBreach-team-alpha-4h)"]

        LiteLLMGW -->|"5. Forward when route is Active"| AppProfile
        AppProfile --> BedrockFM
        BedrockFM -.->|"6. Log Tokens & Identity"| BedrockLogs
        BedrockLogs --> CWFilter
        CWFilter --> CWAlarm
        CWAlarm -.->|"7. Live State Mirrored<br/>Observe-Only Mode"| CrossplaneCW
        CrossplaneCW -->|"8. status.atProvider.stateValue: ALARM"| KyvernoPolicy
        KyvernoPolicy -->|"9. Mutates team-alpha.yaml to rpm: 0"| RouteConfig
        RouteConfig -.->|"10. Hot-Reloads in Memory (Zero Restarts)"| LiteLLMGW
    end
```

### 1. Admission-Level RBAC with Kyverno

Kyverno admission controller process the incoming request by verifying the incoming workload to allowed model. This prevents any model bypassing the model restrictions by manually adding that annotation or forging access to premier frontier models.

>[!NOTE]
> RBAC policy should be established for teams to setup access control via Role/Role-binding mappings and routing the access through the Identity Provider (IdP) to handle the RBAC translation at the cluster boundary. This blog post assumes such access control mechanism exists and does not delve into the implementation details.

1. **`ai.company.internal/allowed-model` is reserved for the platform**: If a developer or CI pipeline attempts to submit a Pod or Job with this annotation already defined, Kyverno blocks admission immediately.
2. **Developers declare intent via `requested-model`**: Client manifests declare what they wish to use through an unprivileged annotation: `ai.company.internal/requested-model: "internal-workhorse"`.
3. **Kyverno verifies against an authoritative entitlement matrix**: Kyverno loads a platform-owned ConfigMap (`team-model-entitlements`) that pre-defines which namespaces are entitled to which virtual model aliases.
4. **Kyverno injects the trusted stamp**: If the requested model is pre-approved for that namespace, Kyverno mutates the pod specification to inject `ai.company.internal/allowed-model: "{{ requestedModel }}"`. Downstream systems trust this annotation because only Kyverno can write it.

```mermaid
flowchart TD
    Submit[Developer Submits Pod / Job Manifest] --> CheckSpoof{Is 'allowed-model' annotation\nalready defined in manifest?}

    CheckSpoof -->|YES: Spoofing Attempt Detected| RejectSpoof[BLOCK IMMEDIATELY\n'Security Violation: allowed-model cannot be set by clients']

    CheckSpoof -->|NO: Clean Manifest Submission| LoadMap[Kyverno loads ConfigMap\nteam-model-entitlements from ai-platform]

    LoadMap --> CheckEntitled{Is requested-model in\nnamespace whitelist?}

    CheckEntitled -->|NO: Unapproved Model Target| RejectEntitlement[BLOCK ADMISSION\n'Access Denied: Namespace not entitled to this model']

    CheckEntitled -->|YES: Authorized Request| StampPod[KYVERNO INJECTS TRUSTED STAMP\nai.company.internal/allowed-model = requested-model\nai.company.internal/stamped-by = kyverno]

    StampPod --> DeployOK[Pod Successfully Scheduled in Cluster]
```

>[!IMPORTANT]
> To prevent constant out-of-sync warnings or infinite reconciliation battles with ArgoCD:
> 1. Instruct ArgoCD to ignore differences on dynamic annotations stamped by Kyverno.
> 2. Instruct ArgoCD to ignore differences on the `litellm-team-routes` ConfigMap `data` field so ArgoCD does not immediately revert circuit breaker route mutations.
```yaml
resource.customizations.ignoreDifferences.all: |
  jqPathExpressions:
    - '.metadata.annotations | select(. != null) | with_entries(select(.key | startswith("ai.company.internal/")))'

resource.customizations.ignoreDifferences.ConfigMap: |
  jsonPointers:
    - /data
```

#### Step 1: The Authoritative Entitlements Matrix (`team-model-entitlements`)

Deploy a centralized ConfigMap in the protected `ai-platform` namespace. Individual development teams have no write permissions to this namespace, ensuring the entitlement mapping cannot be altered by developers:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: team-model-entitlements
  namespace: ai-platform
data:
  # Pre-approved namespace -> allowed virtual model aliases
  team-alpha: "team-alpha-bedrock-profile,internal-workhorse"
  team-beta: "team-beta-bedrock-profile,internal-workhorse"
  team-analytics: "internal-workhorse"
  team-fraud: "team-fraud-bedrock-profile,frontier-reasoning,internal-workhorse"
```

#### Step 2: The Two-Stage Stamping Policy

In Kubernetes admission control, **Mutating Webhooks execute before Validating Webhooks**. If a validating rule simply checked whether `allowed-model` was non-empty, it would see Kyverno's own stamped annotation and reject every legitimate pod.

To resolve this execution order challenge, Rule 1 checks for client tampering, Rule 2 validates that the requested model is authorized for that namespace, and Rule 3 injects the verified platform stamp:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-model-entitlement-and-stamping
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    # Rule 1: Anti-Tamper Check - Reject manifests attempting to set 'allowed-model' or forge 'stamped-by'
    - name: block-spoofed-allowed-model-annotation
      match:
        any:
          - resources:
              kinds: ["Pod", "Job"]
      exclude:
        any:
          - resources:
              namespaces: ["kube-system", "ai-platform", "vllm-serving"]
      validate:
        message: >-
          Security Policy Violation: 'ai.company.internal/allowed-model' and 'stamped-by' are restricted platform attributes.
          Client manifests must not define these annotations directly. Specify 'ai.company.internal/requested-model' instead.
        deny:
          conditions:
            all:
              - key: "{{ request.object.metadata.annotations.\"ai.company.internal/allowed-model\" || '' }}"
                operator: NotEquals
                value: ""
              - key: "{{ request.object.metadata.annotations.\"ai.company.internal/stamped-by\" || '' }}"
                operator: NotEquals
                value: "kyverno-admission-controller"

    # Rule 2: Entitlement Verification - Deny if requested model is not permitted for this namespace
    - name: validate-requested-model-entitlement
      match:
        any:
          - resources:
              kinds: ["Pod", "Job"]
      exclude:
        any:
          - resources:
              namespaces: ["kube-system", "ai-platform", "vllm-serving"]
      context:
        - name: entitlements
          configMap:
            name: team-model-entitlements
            namespace: ai-platform
        - name: rawAllowedModels
          variable:
            value: "{{ entitlements.data.{{request.namespace}} || '' }}"
        - name: allowedModelsList
          variable:
            value: "{{ split('{{rawAllowedModels}}', ',') }}"
        - name: requestedModel
          variable:
            value: "{{ request.object.metadata.annotations.\"ai.company.internal/requested-model\" || 'NONE' }}"
      validate:
        message: >-
          Access Denied: Namespace '{{request.namespace}}' requested model '{{requestedModel}}'.
          Authorized models for this namespace are: [{{rawAllowedModels}}].
          Contact the AI Platform team to request entitlement updates.
        deny:
          conditions:
            any:
              # Deny if namespace has no entry in the entitlements map
              - key: "{{ rawAllowedModels }}"
                operator: Equals
                value: ""
              # Deny if requested model is not in the pre-approved whitelist
              - key: "{{ requestedModel }}"
                operator: AnyNotIn
                value: "{{ allowedModelsList }}"

    # Rule 3: Platform Stamping - Kyverno injects the verified 'allowed-model' annotation
    - name: stamp-verified-allowed-model
      match:
        any:
          - resources:
              kinds: ["Pod", "Job"]
      exclude:
        any:
          - resources:
              namespaces: ["kube-system", "ai-platform", "vllm-serving"]
      context:
        - name: requestedModel
          variable:
            value: "{{ request.object.metadata.annotations.\"ai.company.internal/requested-model\" }}"
      mutate:
        patchStrategicMerge:
          metadata:
            annotations:
              ai.company.internal/allowed-model: "{{ requestedModel }}"
              ai.company.internal/stamped-by: "kyverno-admission-controller"

    # Rule 4: Ensure only the gateway pod can mount Bedrock IAM credentials
    - name: restrict-bedrock-service-account
      match:
        any:
          - resources:
              kinds: ["Pod"]
      exclude:
        any:
          - resources:
              namespaces: ["ai-platform"]
      validate:
        message: "Policy Violation: Unauthorized namespace cannot assume bedrock-gateway-sa."
        pattern:
          spec:
            =(serviceAccountName): "!bedrock-gateway-sa"

    # Rule 5: Forbid privileged containers in AI namespaces
    - name: block-privileged-ai-containers
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["ai-platform", "vllm-serving"]
      validate:
        message: "Policy Violation: Privileged containers are strictly forbidden."
        pattern:
          spec:
            containers:
              - securityContext:
                  =(privileged): false
```

#### How Client Workloads Declare Model Intent

Developers deploy workloads specifying their intended model via `requested-model`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: analytics-worker
  namespace: team-analytics
spec:
  replicas: 1
  selector:
    matchLabels:
      app: analytics-worker
  template:
    metadata:
      labels:
        app: analytics-worker
      annotations:
        # Developer specifies intended model alias; Kyverno will validate and stamp allowed-model
        ai.company.internal/requested-model: "internal-workhorse"
    spec:
      containers:
        - name: worker
          image: python:3.11-slim
          command: ["python", "-c", "import time; time.sleep(3600)"]
```

If an engineer in `team-analytics` changes `requested-model` to `frontier-reasoning`, Kyverno catches the mismatch against `team-model-entitlements` and immediately rejects the `kubectl apply` with an exit code 1.

At the API gateway layer, LiteLLM enforces secondary RBAC by issuing virtual keys bound strictly to specific model subsets. A virtual key created for `team-analytics` will reject requests for premier models at runtime anyways:

```bash
# Generate a team-restricted virtual key in LiteLLM
curl -X POST 'http://litellm-service.ai-platform.svc.cluster.local:4000/key/generate' \
  -H 'Authorization: Bearer sk-cluster-admin-secret' \
  -H 'Content-Type: application/json' \
  -d '{
    "key_alias": "analytics-key",
    "team_id": "team-analytics",
    "max_budget": 250.0,
    "budget_duration": "30d",
    "models": ["internal-workhorse", "internal-workhorse-burst"]
  }'
```

If a client using this key attempts to invoke `frontier-reasoning`, LiteLLM returns an immediate HTTP 400 Bad Request error stating that the key does not possess permissions for that model identifier.

---

### 2. Bedrock Application Inference Profiles: 1-to-1 Team Quotas and Isolation

Calling foundation models using default Bedrock model IDs (such as `anthropic.claude-3-5-sonnet-20241022-v2:0` or `amazon.nova-pro-v1:0`) creates a shared-quota bottleneck. If Team Alpha runs an aggressive batch summarization job, they can exhaust the AWS account's Tokens Per Minute (TPM) limit, throttling real-time customer-facing interactions in Team Beta.

Amazon Bedrock Application Inference Profiles (AIP) solve this by creating distinct logical ARNs for foundation models.

To maintain architectural clarity, Bedrock Application Inference Profiles must map **1-to-1 to a single organizational dimension: either User, Team, or Tenant**. In this architecture, we select the **Team** convention. Mapping 1-to-1 per team aligns infrastructure governance directly with engineering squad ownership, organizational cost centers, and quota boundaries without causing profile management sprawl:

```
arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/team-alpha-aip
```

All Kubernetes resources, LiteLLM aliases, and AWS alarms follow a strict naming convention using a `team-<name>` prefix and descriptive suffixes for uniqueness:

* **Team Identifier**: `team-<name>` (e.g., `team-alpha`, `team-beta`)
* **Bedrock Application Inference Profile**: `team-<name>-aip`
* **LiteLLM Virtual Model Alias**: `team-<name>-bedrock-profile`
* **Crossplane Observe-Only MetricAlarm**: `team-<name>-token-alarm`
* **CloudWatch Metric Alarm**: `Bedrock-TokenBreach-team-<name>-4h`

```mermaid
flowchart LR
    subgraph GatewayRouting["LiteLLM Gateway (Virtual Model Aliases)"]
        TeamACall["Caller: Team Alpha\nRequest Model: team-alpha-bedrock-profile"] -->|1-to-1 Team Route| ProfA
        TeamBCall["Caller: Team Beta\nRequest Model: team-beta-bedrock-profile"] -->|1-to-1 Team Route| ProfB
    end

    subgraph BedrockProfiles["Bedrock Application Inference Profiles (1-to-1 Team Mapping)"]
        ProfA["team-alpha-aip\n(TPM Quota: 250,000\nCost Tag: team-alpha)"]
        ProfB["team-beta-aip\n(TPM Quota: 750,000\nCost Tag: team-beta)"]
    end

    subgraph AWSFoundation["Foundation Models"]
        NovaPro[Amazon Nova Pro / Claude 3.5 Sonnet]
    end

    ProfA --> NovaPro
    ProfB --> NovaPro
```

Using an Application Inference Profile with a 1-to-1 team mapping provides three essential capabilities:

1. **Granular Cost Attribution**: Cost allocation tags((e.g., team ID, application ID, customer/tenant ID, environment) assigned to `team-alpha-aip` flow directly into the AWS Cost and Usage Report (CUR). FinOps teams can trace cloud spend back to the originating team without writing custom billing scraping scripts.
2. **Quota and Rate Limit Isolation**: You can request service quota increases or enforce strict TPS/TPM limits on a specific profile ARN. If `team-alpha` exhausts their allocated TPM ceiling, Bedrock throttles their profile while `team-beta` continues operating at full capacity.
3. **Multi-Region Cross-Region Routing**: Application Inference Profiles can be configured as cross-region profiles. AWS automatically distributes requests across multiple AWS regions (e.g., `us-east-1`, `us-east-2`, and `us-west-2`) to maximize available throughput, bypassing regional capacity bottlenecks while maintaining a single target ARN inside your LiteLLM configuration.

---

### 3. Dual-Plane Observability: Prometheus and CloudWatch Metric Filters

Governing production LLM workloads requires observability at both the cluster network plane and the AWS provider plane.

```mermaid
flowchart TD
    subgraph ClusterObservability["Cluster-Side Observability (Real-Time Sub-Second)"]
        LiteLLMPod[LiteLLM Gateway Pod] -->|Exposes /metrics:4000| Prom[Prometheus Server]
        ClientApps[Client Application Pods] -->|App HTTP Latencies| Prom
        Prom --> Grafana[Grafana Real-Time Dashboards]
    end

    subgraph CloudWatchObservability["CloudWatch Provider Observability (Audit & Billing)"]
        LiteLLMPod -->|Injects requestMetadata| BedrockAPI[Amazon Bedrock Engine]
        BedrockAPI -->|Invocation Logs| LogGroup["/aws/bedrock/invocation-logs"]
        LogGroup --> MetricFilter["CloudWatch Metric Filters\n(Tokens by UserId/TeamId)"]
        MetricFilter --> Alarms["CloudWatch Rolling Window Alarms\n(4h, 8h, 12h Windows)"]
    end
```

#### Cluster-Plane: Prometheus Integration

LiteLLM exposes a Prometheus `/metrics` endpoint that tracks internal request routing, latency histograms, and budget consumption in real time:

* `litellm_requests_metric`: Tracks request totals partitioned by `model`, `team`, and `user`.
* `litellm_total_tokens`: Tracks token counters partitioned by `token_type` (`input` vs. `output`), `model`, and `team_id`.
* `litellm_remaining_team_budget_metric`: Exposes remaining financial balances per team, allowing platform engineers to build real-time Grafana alerts before a team hits zero balance.
* `litellm_latency_per_output_token`: Tracks generation speeds to identify decode bottlenecks.

Platform engineers configure a standard Prometheus `PodMonitor` or `ServiceMonitor` to scrape the gateway pods every 15 seconds:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: litellm-monitor
  namespace: ai-platform
spec:
  selector:
    matchLabels:
      app: llm-gateway
  endpoints:
    - port: http-metrics
      path: /metrics
      interval: 15s
```

#### Provider-Plane: CloudWatch Invocation Logs & Metric Filters

For requests routed out of the cluster to Amazon Bedrock, the gateway injects the caller's identity directly into the API invocation payload:

```python
# Injection of identity inside LiteLLM's downstream Bedrock adapter
response = bedrock_runtime.converse(
    modelId="arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/team-analytics-profile",
    messages=[{"role": "user", "content": [{"text": user_prompt}]}],
    requestMetadata={
        "userId": "user_49102",
        "teamId": "team-analytics",
        "costCenter": "CC-8402"
    }
)
```

With Bedrock **Model Invocation Logging** directed to a CloudWatch Log Group (`/aws/bedrock/invocation-logs`), Bedrock records the full metadata along with exact input and output token counts for every execution.

Platform engineers configure a **CloudWatch Metric Filter** to isolate token consumption per team:

* **Filter Pattern**: `{ $.requestMetadata.teamId = * && $.inputTokenCount = * && $.outputTokenCount = * }`
* **Metric Name**: `TotalTokensConsumed`
* **Metric Namespace**: `GenerativeAI/Governance`
* **Metric Value**: `$inputTokenCount + $outputTokenCount`
* **Dimension Declarations**:
  * `TeamId = $.requestMetadata.teamId`

>[!NOTE]
> CloudWatch metric dimensions act as strict composite keys. If a metric filter publishes both `TeamId` and `UserId` on the same metric stream, a CloudWatch alarm querying only `TeamId` will evaluate as `INSUFFICIENT_DATA`. We publish `TeamId` as a dedicated single-dimension metric stream so the team-level rolling alarm accurately aggregates token consumption across all users in that team.

---

### 4. Declarative Zero-Downtime Circuit Breaking with Crossplane, Kyverno, and LiteLLM Model Aliasing

Setting a static 24-hour token budget creates an operational vulnerability. If an engineer deploys an autonomous agent that enters an infinite recursion loop at 9:00 AM, a daily budget evaluation allows that loop to burn 100% of the team's daily allocation in thirty minutes.

To catch anomalous traffic patterns before they cause financial harm, configure multi-tier rolling window alarms in Amazon CloudWatch:

1. **4-Hour Window (Catastrophic Surge Circuit Breaker)**: Evaluates the sum of `TotalTokensConsumed` over a 4-hour rolling window with a strict threshold (e.g., 2,000,000 tokens). This catches runaway loops, broken retry configurations, or denial-of-service traffic patterns within minutes.
2. **8-Hour Window (Single-Shift Ceiling)**: Tracks consumption across a standard business shift (e.g., 4,500,000 tokens). Prevents a team from depleting their weekly allocation during a single daytime spike.
3. **12-Hour Window (Half-Day Governance Cap)**: Enforces a half-day stabilization cap (e.g., 6,000,000 tokens), preventing automated overnight batch runs from overrunning cluster quotas.

```mermaid
graph LR
    subgraph MultiWindowEvaluation["Tiered Rolling Window Defense"]
        Window4h["4-Hour Rolling Window\nLimit: 2M Tokens\nTarget: Catches Runaway Loops"]
        Window8h["8-Hour Rolling Window\nLimit: 4.5M Tokens\nTarget: Shift Overuse Cap"]
        Window12h["12-Hour Rolling Window\nLimit: 6M Tokens\nTarget: Half-Day Budget Ceiling"]
    end

    Window4h -->|Breach| CWAlarmState[CloudWatch Metric Alarm State: ALARM]
    Window8h -->|Breach| CWAlarmState
    Window12h -->|Breach| CWAlarmState
    CWAlarmState --> CrossplaneCRD[Crossplane Observe-Only MetricAlarm\nteam-alpha-token-alarm]
    CrossplaneCRD --> KyvernoPolicy[Kyverno Dynamic Policy Engine\ndynamic-team-inference-circuit-breaker]
    KyvernoPolicy --> LiteLLMConfigMap["ConfigMap: litellm-team-routes\nMutates team-alpha.yaml to rpm: 0"]
```

#### The Architecture of Model Aliasing and Modular Directory Configurations

Traditional circuit breakers try to inject runtime blocklists, flush Redis keys, or terminate client pods.

The cleanest declarative approach inside Kubernetes is **Model Aliasing paired with Modular Directory Configurations**:

1. **Virtual Model Aliasing**: Client microservices never call raw AWS foundation model IDs or physical Bedrock ARNs directly. Microservices target a virtual model profile alias assigned to their team (e.g., `team-alpha-bedrock-profile`).
2. **Modular Multi-File ConfigMaps**: In Kubernetes, `ConfigMap.data` is a `map[string]string`. If you store all team routes in a single monolithic `config.yaml` string, a Strategic Merge Patch will overwrite the entire string, erasing all other teams' routes. To prevent this, we split LiteLLM's configuration into two ConfigMaps:
   * `litellm-base-config`: Contains `/etc/litellm/base.yaml` (global settings, cache params, base models like `internal-workhorse` and `frontier-reasoning`).
   * `litellm-team-routes`: Contains modular per-team route files as separate keys in `data` (`team-alpha.yaml`, `team-beta.yaml`). When Kyverno mutates `team-alpha.yaml`, it updates **only that specific key**, leaving all other teams completely untouched.
3. **Native Rate-Limiting via `rpm: 0`**: Rather than hijacking global `NotFoundError` (which turns legitimate model typos into false token breach alerts), Kyverno mutates Team Alpha's route to set `rpm: 0`. LiteLLM natively intercepts calls to zero-RPM routes and returns an immediate `RateLimitError` (HTTP 429 Too Many Requests) with `Retry-After` headers.

#### Step 1: The Core LiteLLM Modular Configuration

Deploy the base configuration ConfigMap containing shared settings:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-base-config
  namespace: ai-platform
data:
  base.yaml: |
    general_settings:
      master_key: os.environ/LITELLM_MASTER_KEY
      store_model_in_db: false

    litellm_settings:
      cache: true
      cache_params:
        type: redis
        host: valkey-service.ai-platform.svc.cluster.local
        port: 6379
      drop_params: true
      set_verbose: false

    router_settings:
      routing_strategy: usage-based-routing
      redis_host: valkey-service.ai-platform.svc.cluster.local
      redis_port: 6379
      enable_pre_call_checks: true
```

Deploy the modular team routes ConfigMap where each team owns a dedicated key:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-team-routes
  namespace: ai-platform
data:
  team-alpha.yaml: |
    model_list:
      - model_name: team-alpha-bedrock-profile
        litellm_params:
          model: bedrock/arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/team-alpha-aip
          aws_region_name: us-east-1
          rpm: 10000

  team-beta.yaml: |
    model_list:
      - model_name: team-beta-bedrock-profile
        litellm_params:
          model: bedrock/arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/team-beta-aip
          aws_region_name: us-east-1
          rpm: 10000
```

#### Step 2: Secure AWS Authentication via Crossplane IRSA

Crossplane requires read-only permissions to poll CloudWatch alarms without storing static AWS access keys inside the cluster.

Create an IAM Role (`CrossplaneCloudWatchObserverRole`) with read-only CloudWatch permissions:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowCloudWatchAlarmObservation",
            "Effect": "Allow",
            "Action": [
                "cloudwatch:DescribeAlarms",
                "cloudwatch:GetMetricData",
                "cloudwatch:ListMetrics"
            ],
            "Resource": "*"
        }
    ]
}
```

Bind this IAM role to the Crossplane provider ServiceAccount using EKS Pod Identity or IAM Roles for Service Accounts (IRSA):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cloudwatch-provider-sa
  namespace: crossplane-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/CrossplaneCloudWatchObserverRole
---
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: aws-provider-config
spec:
  credentials:
    source: WebIdentity
    webIdentity:
      roleARN: arn:aws:iam::123456789012:role/CrossplaneCloudWatchObserverRole
```

#### Step 3: Track the Token Breach Alarm via Crossplane in Observe-Only Mode

Deploy a `MetricAlarm` custom resource using the Upbound AWS CloudWatch provider.

By declaring `managementPolicies: ["Observe"]`, Crossplane polls the live AWS CloudWatch alarm without creating, modifying, or deleting the alarm on AWS:

```yaml
apiVersion: cloudwatch.aws.upbound.io/v1beta1
kind: MetricAlarm
metadata:
  name: team-alpha-token-alarm
  namespace: ai-platform
  annotations:
    crossplane.io/external-name: "Bedrock-TokenBreach-team-alpha-4h"
spec:
  # Observe-only: do not mutate AWS resources; poll live status into Kubernetes
  managementPolicies: ["Observe"]
  forProvider:
    region: us-east-1
    alarmName: "Bedrock-TokenBreach-team-alpha-4h"
    comparisonOperator: GreaterThanThreshold
    evaluationPeriods: 1
    metricName: TotalTokensConsumed
    namespace: GenerativeAI/Governance
    period: 14400
    statistic: Sum
    threshold: 2000000
    dimensions:
      - name: TeamId
        value: team-alpha
  providerConfigRef:
    name: aws-provider-config
```

Crossplane continuously synchronizes the live alarm status into the custom resource status block:

```yaml
status:
  atProvider:
    stateValue: "ALARM" # Reflects actual live AWS state: OK, ALARM, or INSUFFICIENT_DATA
    stateReason: "Threshold Crossed: 1 datapoint [2450000.0] was greater than the threshold (2000000.0)."
    dimensions:
      - name: TeamId
        value: team-alpha
```

#### Step 4: Multi-Tenant Kyverno Route Mutation Policy

Instead of writing separate policies for every team, a single Kyverno `ClusterPolicy` evaluates the incoming alarm resource, extracts the target team from the alarm dimensions, and mutates only that team's route key in `litellm-team-routes`.

The rule uses Kyverno context variables and the `choice()` conditional function to toggle `rpm: 0` during breaches:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: dynamic-team-inference-circuit-breaker
spec:
  rules:
    - name: evaluate-and-patch-team-route
      match:
        any:
          - resources:
              kinds:
                - cloudwatch.aws.upbound.io/v1beta1/MetricAlarm
              names:
                - "team-*-token-alarm"
              namespaces:
                - ai-platform
      context:
        # 1. Extract teamId from the alarm dimension (safe against hyphens in team names)
        - name: teamId
          variable:
            value: "{{ request.object.spec.forProvider.dimensions[?name=='TeamId'].value | [0] }}"
        # 2. Extract the live alarm state string reported by Crossplane
        - name: alarmState
          variable:
            value: "{{ request.object.status.atProvider.stateValue }}"
      mutate:
        targets:
          - apiVersion: v1
            kind: ConfigMap
            name: litellm-team-routes
            namespace: ai-platform
        patchStrategicMerge:
          data:
            # Surgically patches only team-{{teamId}}.yaml without touching other keys
            team-{{teamId}}.yaml: |
              model_list:
                - model_name: team-{{teamId}}-bedrock-profile
                  litellm_params:
                    model: bedrock/arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/team-{{teamId}}-aip
                    aws_region_name: us-east-1
                    rpm: {{ choice('{{alarmState}}' == 'ALARM', 0, 10000) }}
```

This policy delivers two critical operational behaviors:

* **Surgical Route Throttling**: When Crossplane reports `ALARM`, Kyverno patches `data["team-alpha.yaml"]` so that `rpm: 0`. LiteLLM's router immediately rejects calls to `team-alpha-bedrock-profile` with a native `RateLimitError` (HTTP 429 Too Many Requests).
* **Bi-Directional Auto-Recovery**: The second the rolling window clears on CloudWatch and Crossplane reports `OK`, the `choice()` function automatically reverts `rpm: 10000`, restoring traffic without human intervention.

#### Step 5: Zero-Restart Dynamic Config Hot-Reload in LiteLLM (Directory Mounts)

To allow LiteLLM to watch for configuration changes without pod restarts, we mount `/etc/litellm/routes` as a **directory mount**. LiteLLM is configured with `LITELLM_WATCH_CONFIG=True` and passed both the base configuration and the routes directory:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm
  namespace: ai-platform
spec:
  replicas: 2
  selector:
    matchLabels:
      app: llm-gateway
  template:
    metadata:
      labels:
        app: llm-gateway
    spec:
      containers:
        - name: litellm
          image: ghcr.io/berriai/litellm:main-latest
          args: ["--config", "/etc/litellm/base.yaml", "/etc/litellm/routes/"]
          env:
            - name: LITELLM_WATCH_CONFIG
              value: "True" # Enables live, zero-restart directory file watching
          volumeMounts:
            - name: base-config-volume
              mountPath: /etc/litellm
            - name: team-routes-volume
              mountPath: /etc/litellm/routes
      volumes:
        - name: base-config-volume
          configMap:
            name: litellm-base-config
        - name: team-routes-volume
          configMap:
            name: litellm-team-routes
```

When Kyverno patches `litellm-team-routes`, Kubelet updates the `..data` symlink inside `/etc/litellm/routes/`. LiteLLM's directory watcher detects the change and reloads the active routing table in memory within 500 milliseconds, preserving existing streaming connections while immediately throttling the breached team.

#### The Declarative In-Cluster Feedback Loop

```mermaid
sequenceDiagram
autonumber
participant Bedrock as Amazon Bedrock API
participant CW as "CloudWatch Metric Alarm (4h)"
participant CP as "Crossplane MetricAlarm (Observe-Only)"
participant Kyv as "Kyverno (dynamic-team-inference-circuit-breaker)"
participant CM as "ConfigMap: litellm-team-routes"
participant GW as "LiteLLM Gateway (LITELLM_WATCH_CONFIG: True)"
participant Client as "Client Application (Team Alpha)"

Bedrock->>CW: Invocation Logs record surge (over 2M tokens)
CW->>CW: State transitions to ALARM
CP->>CW: Reconcile and fetch live alarm status
CP->>CP: Update MetricAlarm status.atProvider.stateValue = ALARM
Kyv->>CP: Detect status update event on team-alpha-token-alarm
Kyv->>Kyv: Evaluate context: teamId=team-alpha, alarmState=ALARM
Kyv->>CM: Mutate team-alpha.yaml key to rpm: 0
CM-->>GW: Directory symlink updates - watcher hot-reloads routing table
Client->>GW: POST /v1/chat/completions (model: team-alpha-bedrock-profile)
GW->>GW: Route matches team-alpha-bedrock-profile with rpm: 0 -> RateLimitError
GW-->>Client: HTTP 429 Too Many Requests (Rate limit exceeded: 0 RPM allowed)

Note over CW,Client: Rolling Window Clears (Cooldown Period Expires)
CW->>CW: State transitions to OK
CP->>CW: Reconcile live alarm status
CP->>CP: Update MetricAlarm status.atProvider.stateValue = OK
Kyv->>CM: Mutate team-alpha.yaml key back to rpm: 10000
CM-->>GW: Hot-reload restores active route - Team Alpha traffic resumes
```

#### Multi-Team Scaling Blueprint

To onboard a new team (e.g., Team Beta) into this circuit breaker system, platform engineers do not write new scripts or modify Kyverno policies. You simply declare a new `MetricAlarm` custom resource adhering to the naming convention:

```yaml
apiVersion: cloudwatch.aws.upbound.io/v1beta1
kind: MetricAlarm
metadata:
  name: team-beta-token-alarm # Matches 'team-*-token-alarm' prefix pattern
  namespace: ai-platform
  annotations:
    crossplane.io/external-name: "Bedrock-TokenBreach-team-beta-4h"
spec:
  managementPolicies: ["Observe"]
  forProvider:
    region: us-east-1
    alarmName: "Bedrock-TokenBreach-team-beta-4h"
    comparisonOperator: GreaterThanThreshold
    evaluationPeriods: 1
    metricName: TotalTokensConsumed
    namespace: GenerativeAI/Governance
    period: 14400
    statistic: Sum
    threshold: 4500000
    dimensions:
      - name: TeamId
        value: team-beta
  providerConfigRef:
    name: aws-provider-config
```

The instant this manifest is applied to the cluster:

1. Crossplane begins polling CloudWatch for Team Beta's token consumption.
2. The existing Kyverno policy automatically matches `team-beta-token-alarm`.
3. If Team Beta breaches their threshold, Kyverno isolates `team-beta-bedrock-profile` without touching Team Alpha or global cluster workloads.

The entire circuit breaker lifecycle is declared in Git, reconciled by Kubernetes controllers, and enforced at the gateway with zero downtime.

---

## The ML Engineering Reality Check: When Self-Hosting with vLLM Makes Sense

It is easy to look at raw hardware spreadsheets and conclude that hosting models yourself will save your company hundreds of thousands of dollars.

In practice, deploying self-hosted models purely to run generic, off-the-shelf open weights (like stock Llama 3.1 8B without modifications) is frequently an operational misstep. Unless your continuous token volume comfortably exceeds 2 to 4 billion tokens per month, the human overhead of managing GPU driver upgrades, node recycling, and cluster monitoring easily outweighs the modest savings on your Bedrock invoice.

Self-hosting with dedicated inference engines like vLLM becomes a distinct advantage when your machine learning engineering team possesses the maturity to customize models:

```mermaid
mindmap
  root((When Does Self-Hosting\nWith vLLM Win?))
    Domain Fine-Tuning:::whiteNode
      Task-Specific LoRA Adapters
      Small Specialized Models Beating Large General Models
      Proprietary Enterprise Weights
    Advanced Quantization
      FP8 and AWQ Kernel Acceleration
      Doubling Concurrency Per VRAM Slice
      Slashing Hardware Footprints
    Serving Optimizations
      Dynamic Prefix Caching
      Speculative Decoding Pairs
      Custom Scheduling / Chunked Prefill
    Extreme Compliance
      Zero External Network Egress
      Air-Gapped Sovereign Enclaves
      Full Data Lineage Ownership
```

### 1. Fine-Tuning and Domain Adaptation

A common industry finding is that a finely tuned 8-billion parameter model, trained specifically on high-quality internal company datasets (such as internal support tickets, database schemas, or proprietary legal documents), will consistently outperform a generic 70-billion parameter foundation model on domain-specific benchmarks.

A fine-tuned 8B model requires only a single NVIDIA L4 GPU ($0.85/hr). Serving that same workload through a proprietary managed 70B model or frontier API costs roughly 10x to 15x more per token. If your ML engineering team possesses a reliable fine-tuning pipeline, self-hosting those weights on a dedicated engine delivers a significant competitive and economic advantage.

### 2. Multi-LoRA Adapter Serving

If your product offers personalized AI assistance across multiple business verticals, you do not need to deploy separate base models for each vertical.

Modern serving runtimes allow an engineering team to load a single base model into GPU memory once, and dynamically attach hundreds of lightweight LoRA adapters (ranging from 10 MB to 100 MB each) on the fly based on incoming prompt headers. This capability is difficult to replicate on managed serverless platforms without paying steep dedicated endpoint fees for every single adapter variant.

### 3. Deep Quantization Engineering (FP8 and AWQ)

Running a model in standard 16-bit precision requires 2 bytes of VRAM per parameter. By quantizing weights to 8-bit (FP8) or 4-bit (AWQ) formats, your team cuts the model's memory footprint in half or by three-quarters with minimal loss in benchmark accuracy.

This allows you to run an 8B model comfortably on a lower-tier accelerator, doubling your maximum concurrent user streams per node and cutting your hardware cost per token in half. Managed APIs rarely expose low-level quantization kernel selections to the end user.

---

## Production Failure Modes: Breaking Point and What can be Avoided

Engineering architectures look clean on paper. When deploying hybrid inference gateways under heavy production traffic, systems break in subtle ways. Here are the failure modes encountered and how to address them:

### 1. The Redis/Valkey Cache Bottle-Neck

In high-concurrency configurations, having the LiteLLM gateway synchronously update token balances in Redis on every streaming chunk introduces severe latency jitter.

* **Breaking Point**: Token streaming over Server-Sent Events (SSE) stalled because the proxy executed atomic counter increments against Redis for every token packet.
* **Fix**: Buffer usage tracking locally in gateway process memory and flush aggregated token metrics to the Valkey cache asynchronously at the end of the request stream or in 5-second intervals.

### 2. Upstream Timeout Cascades

When Bedrock throttled requests during sudden traffic bursts, LiteLLM's retry loop held incoming client connections open.

* **Breaking Point**: Client connections accumulated rapidly. The internal Application Load Balancer hit its target group connection limits, causing the gateway pods to crash from memory exhaustion.
* **Fix**: Configure strict timeouts (`timeout: 15`), drop retries to a maximum of 2, and implement aggressive circuit breaking. If Bedrock returns two consecutive HTTP 429 responses, LiteLLM immediately redirects subsequent traffic to secondary providers (e.g., OpenAI or an alternate AWS region) without attempting retries on the primary endpoint.

### 3. Streaming Chunk Reassembly Errors

When proxying streaming responses between different model providers, chunk formats vary subtly. Anthropic SSE chunks, Bedrock converse streams, and OpenAI chat completion streams format delta payloads differently.

* **Breaking Point**: Front-end applications parsing SSE chunks threw JSON parsing exceptions when the gateway dynamically switched providers mid-stream during an automated fallback.
* **Fix**: Enable LiteLLM's standard response transformation headers, ensuring that regardless of which provider serves the completion, the outgoing SSE stream strictly matches the OpenAI `/v1/chat/completions` protocol specification.

---

## Frequently Asked Questions (FAQ)

### What is the typical token volume where self-hosting becomes cheaper than Amazon Bedrock?

For an 8-billion parameter model like Llama 3.1 8B, the financial tipping point typically occurs between 2 and 4 billion tokens per month, assuming your workload maintains a sustained baseline utilization above 60%. If your monthly volume is below 500 million tokens, or if your traffic experiences high diurnal volatility with near-zero activity at night, Amazon Bedrock serverless inference is almost always more cost-effective.

### Can LiteLLM handle streaming tokens with sub-millisecond overhead?

Yes. LiteLLM is designed as an asynchronous Python proxy utilizing `httpx` and `asyncio`. In production deployments on Amazon EKS, the gateway adds between 2 and 5 milliseconds of network latency overhead to the initial Time-to-First-Token (TTFT). For subsequent streaming chunks, the proxy pipes bytes directly through asynchronous generator buffers, introducing virtually no perceptible delay to the end-user.

### How does Kyverno secure AI workloads better than standard Kubernetes RBAC?

Standard Kubernetes RBAC controls cluster-level API actions (such as who can create a Pod or read a Secret). It cannot inspect the internal properties of a manifest at admission time. Kyverno evaluates the contents of deployment manifests before they are scheduled. It verifies that pods requesting GPU resources have explicit resource limits, ensures containers run as non-root, checks that client pods only target whitelisted models allowed for their namespace, and strictly blocks any pod outside the authorized `ai-platform` namespace from mounting the AWS IAM ServiceAccount associated with Amazon Bedrock.

### What is the difference between Time-to-First-Token (TTFT) and Inter-Token Latency (ITL)?

Time-to-First-Token measures the delay between sending a request and receiving the initial token chunk. This window includes network transit, gateway routing overhead, queue waiting time, and prompt prefill compute time. Inter-Token Latency measures the time between each subsequent generated token during the decode phase. TTFT is primarily determined by prompt length and compute availability, while ITL is determined by model parameter size and GPU memory bandwidth.

### Why use multi-hour rolling window alarms (4h, 8h, 12h) instead of standard 24-hour daily quotas?

A standard 24-hour daily token budget creates a dangerous blind spot for autonomous agent applications. If a microservice enters an unhandled recursion loop or experiences an uncontrolled retry cascade, it can burn an entire team's 24-hour token budget in less than an hour before alerting kicks in. Tiered rolling windows protect your budget at different operational horizons: a 4-hour window catches catastrophic automated loops immediately, an 8-hour window caps usage across a standard business shift, and a 12-hour window enforces half-day stabilization limits.

### How does virtual model route mutation achieve zero-downtime circuit breaking without restarting LiteLLM pods?

When LiteLLM runs with `LITELLM_WATCH_CONFIG=True` pointing to a directory (`--config /etc/litellm/base.yaml /etc/litellm/routes/`), the process continuously monitors directory symlinks for filesystem modification events. When Kyverno patches the `litellm-team-routes` ConfigMap to throttle a team's virtual model alias (`rpm: 0`), Kubernetes atomically updates the directory symlink in `/etc/litellm/routes/`. LiteLLM's internal watcher detects this change and reloads the active routing table in process memory within 500 milliseconds. Existing TCP streams and completions for other models continue unaffected, while new requests for the breached team immediately receive an HTTP 429 response without terminating or restarting gateway pods.

---

## Architecture Checklist and Evaluation Next Steps

Before making any infrastructure commitments, you can follow this phased implementation path:

1. **Deploy Telemetry First**: Deploy LiteLLM on Amazon EKS with Valkey caching. Route 100% of your current traffic through the gateway to Amazon Bedrock serverless endpoints.
2. **Collect 30 Days of Data**: Track your input-to-output token ratios, your peak-to-base concurrency ratio, and your actual monthly token volumes per model tier.
3. **Calculate Your Utilization Curve**: Apply the formula:
   $$\text{Utilization \%} = \frac{\text{Monthly Baseline Tokens}}{\text{Max Theoretical Hardware Throughput}}$$
   If utilization is below 50%, remain on Amazon Bedrock.
4. **Deploy Hybrid Slicing**: If volume crosses 2 billion tokens with a stable baseline, provision an internal GPU node group running an optimized inference engine like vLLM. Configure LiteLLM to serve your baseline traffic locally while keeping Bedrock configured as an automated burst and fallback target.
5. **Enforce Governance**: Apply Kyverno admission policies to lock down EKS Pod Identity and restrict model targets per namespace. Deploy Bedrock Application Inference Profiles with 1-to-1 Team mapping, and declare Crossplane Observe-Only MetricAlarm custom resources to let Kyverno dynamically swap virtual model routes to error targets during budget breaches with zero pod restarts.

## References & Technical Documentation

* [Deploying LLMs on Amazon EKS using vLLM Deep Learning Containers](https://aws.amazon.com/blogs/machine-learning/deploy-llms-on-amazon-eks-using-vllm-deep-learning-containers/)
* [AWS Samples: Production LiteLLM Bedrock Gateway on EKS](https://github.com/aws-samples/sample-litellm-bedrock-gateway-on-eks)
* [Implementing Resilience Patterns with Amazon Bedrock and LLM Gateways](https://aws.amazon.com/blogs/machine-learning/implementing-resilience-patterns-with-amazon-bedrock-and-llm-gateway/)
* [Bedrock inference profiles](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles.html)
* [Configuring Model Providers with LiteLLM](https://docs.aws.amazon.com/bedrock-agentcore/latest/APIReference/API_HarnessLiteLlmModelConfig.html)
* [Policy Management with Kyverno on Amazon EKS](https://aws.amazon.com/blogs/containers/easy-as-one-two-three-policy-management-with-kyverno-on-amazon-eks/)
