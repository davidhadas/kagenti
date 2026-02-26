# Kagenti Implementation Design: Consolidated Compositional Agent Platform Architecture

**Authors**: Kagenti Team

**Begin Design Discussion**: 2026-02-20

**Status**: Draft

**Supersedes**: [compositional-agent-platform-design.md](compositional-agent-platform-design.md)

**Checklist**:

- [ ] AgentRuntime CR implementation (identity + observability)
- [ ] AgentCard CR adaptation (selector change)
- [ ] Mutating webhook implementation
- [ ] Layered defaults mechanism (cluster / namespace)
- [ ] Controller consolidation (istiod pattern)
- [ ] Migration tooling
- [ ] Documentation updates
- [ ] Integration tests
- [ ] E2E tests
- [ ] Performance benchmarks

---

## Implementation Horizons

This proposal distinguishes between **short-term** and **long-term** goals. The current design reflects what is practical to implement now, while acknowledging that certain capabilities will be introduced as the platform matures.

### Short-Term (Current Design)

The immediate goal is a working, secure composition model with minimal complexity:

- **Explicit workload opt-in**: Developers label workloads with `kagenti.io/inject: enabled` to trigger AuthBridge sidecar injection. This is a conscious, visible act in the workload manifest.
- **Webhook with ConfigMap-based defaults**: The webhook reads cluster-level defaults from two ConfigMaps in the `kagenti-webhook-system` namespace:
  - `kagenti-webhook-feature-gates` — controls which AuthBridge components are enabled globally (`globalEnabled`, `envoyProxy`, `spiffeHelper`, `clientRegistration`)
  - `kagenti-webhook-defaults` — provides default container images, proxy port configuration, and per-component resource requests/limits for all injected sidecars
- **Two workload labels required**: `kagenti.io/inject: enabled` (injection opt-in) and `kagenti.io/type` (classification) are the only labels developers need to add.

This is the model described in detail throughout this document.

### Long-Term (Future Enhancements)

As the platform matures, the following improvements are planned:

- **CR-configured webhook defaults**: Two dedicated CRDs will replace static ConfigMaps with a proper Kubernetes-native API for managing defaults:
  - `AgentRuntimeClusterConfig` (cluster-scoped) — stores cluster-wide defaults, set by cluster administrators
  - `AgentRuntimeConfig` (namespace-scoped) — stores namespace-level overrides, deployed alongside workloads in each team namespace; overrides `AgentRuntimeClusterConfig` for any setting it specifies, set by cluster administrators


- **Move webhook injection target from workload objects to pods**: The current `MutatingWebhookConfiguration` targets higher-level workload objects (`deployments`, `statefulsets`, `daemonsets`). This means the webhook mutates the pod template embedded inside those objects — the injected sidecar containers are stored directly in the Deployment's `spec.template` in etcd.

  This creates a structural conflict with GitOps-based continuous delivery pipelines (Argo CD, Flux, and similar tools):

  - CD tools continuously reconcile live Kubernetes resources against a Git source of truth (the Deployment manifest in a repository).
  - When the webhook mutates a Deployment's pod template, the live Deployment diverges from the Git-stored manifest — the live object contains injected sidecars that the Git manifest does not.
  - CD tools detect this as configuration drift. Depending on their configuration they either raise a continuous alert (false positive noise) or actively remediate the drift by reverting the mutation — stripping the injected sidecars on the next sync cycle and leaving pods without identity infrastructure.
  - Additionally, mutating the Deployment's pod template can overwrite configuration the developer intentionally placed there — volume mounts, secret references, environment variables — because the webhook and the developer are competing to define the same object.

  The proven alternative — used by Istio, Linkerd, and Vault Agent injector — is to register the webhook against `pods` at `CREATE` time instead:

  - The webhook fires when Kubernetes instantiates a pod from any workload controller (a Deployment rollout, a StatefulSet scale event, a Job run, etc.).
  - The Deployment manifest in Git remains unmodified — no injected sidecars appear in the pod template spec.
  - CD tools see no drift because the Deployment object is unchanged from what Git describes.
  - Injected sidecars are visible at the pod level (`kubectl get pod -o yaml`) but not in the Deployment, which reflects only the developer's intended container definition.
  - Conflicts with developer-defined volume mounts and secret references are confined to pod creation time and do not affect the stored Deployment spec.

  This change requires updating the `MutatingWebhookConfiguration` `resources` list from `deployments/statefulsets/daemonsets` to `pods`, and updating the webhook handler to operate on `Pod` admission requests. The `objectSelector` logic — filtering on `kagenti.io/inject: enabled` — would move to the pod's labels (propagated from the workload's pod template labels) rather than the Deployment's metadata labels.



These long-term goals are **not implemented in the current design** and are called out here to provide direction without overcomplicating the immediate implementation.

---

## Summary/Abstract

This design proposal consolidates two earlier proposals into a unified architecture for managing AI agent workloads on Kubernetes:

1. The original **Compositional Agent Platform Architecture** ([PR #531](https://github.com/kagenti/kagenti/pull/531)), which proposed replacing the monolithic `Agent` CR with a mutating webhook plus three independent pillar CRs (`TokenExchange`, `AgentTrace`, `AgentCard`).
2. A **counter-proposal** advocating for a single `AgentRuntime` reference CR, removal of workload labels, and controller-based injection instead of a webhook.

This consolidated design retains the strengths of both while resolving their disagreements:

- **Workload-level injection** uses an explicit opt-in label — developers add `kagenti.io/inject: enabled` to workloads they want injected
- **Workload labels are retained** for classification (agents vs. tools) — developers add `kagenti.io/type` and `kagenti.io/inject: enabled` to opt in
- **TokenExchange and AgentTrace are consolidated** into a single `AgentRuntime` CR — reducing resource count while preserving configurability
- **AgentCard remains a separate CR** — different cardinality model, existing implementation, and distinct concern (discovery vs. runtime)
- **The mutating webhook is retained** for admission-time sidecar injection — security-first, already implemented
- **Layered defaults** (cluster → namespace → per-workload CR) are introduced — most workloads need no CR at all
- **The operator reconciles AgentRuntime CRs** for dynamic reconfiguration — complementary to the webhook, not a replacement

The result is a two-CR model (`AgentRuntime` + `AgentCard`) atop a label-and-webhook foundation, with layered defaults that minimize per-workload configuration.

### Two Distinct Configuration Concerns

This architecture separates configuration into two fundamentally different lifecycle stages that must not be conflated:

**1. Admission-time configuration** — occurs when a workload is first created (or updated). The mutating webhook intercepts the request, merges cluster defaults → namespace defaults → AgentRuntime CR overrides, and injects the AuthBridge sidecars with the resulting configuration baked in. This is a one-shot operation: the webhook fires, sidecars are injected, and the pod starts. Security is guaranteed — a workload cannot bypass injection once it carries `kagenti.io/inject: enabled`.

**2. Reconfiguration of running workloads** — occurs after pods are already running. When defaults or an AgentRuntime CR change, those changes must reach the already-running sidecars without restarting pods. This is handled by the operator, which detects configuration drift and propagates updates to running sidecars (see [Configuration Propagation](#configuration-propagation-open-design)). Note that some changes — such as modifications to injected sidecar images or init container configuration — inherently require a pod restart.

These two concerns are handled by different components (webhook vs. operator), operate at different points in the workload lifecycle, and have different latency and consistency requirements. Design decisions in one stage should not be conflated with the other.

### Architecture at a Glance

```
Developer Creates Standard Deployment
  + kagenti.io/inject: enabled   (opts in to AuthBridge injection)
  + kagenti.io/type: agent (or tool)
        ↓
Webhook Injects AuthBridge Sidecars (workload is labeled)
  • Reads cluster/namespace defaults
  • Init container (network setup)
  • SPIFFE helper (identity)
  • Client registration (IdP integration)
  • Envoy proxy (outbound token exchange)
        ↓
Agent Pod Running with Secure Defaults
  • Identity and auth fully configured
  • OTEL configured from defaults
  • No CRs required for standard operation
        ↓
Optional: Developer Creates CRs
  • AgentRuntime → override platform defaults for this workload
  • AgentCard → enable discovery
        ↓
Operator Reconciles
  • AgentRuntime: Propagates config to sidecars
  • AgentCard: Fetches and caches agent cards
  • Sidecars reconfigure dynamically where possible
  • Pod restarts may be required for some changes (e.g. sidecar image updates)
```

---

## Background

### Prior Proposals

**Original Proposal (Three Pillars)**: Proposed a mutating webhook triggered by `kagenti.io/inject: enabled` label, plus three independent pillar CRs (`TokenExchange`, `AgentTrace`, `AgentCard`). Strong on composition-over-inheritance thesis, proven ecosystem analysis, and working webhook implementation. Weakness: four objects per fully-configured agent.

**Counter-Proposal (AgentRuntime)**: Proposed a single `AgentRuntime` CR with `workloadRef`, eliminating labels and the webhook in favor of controller-based injection. Strong on auditability and single-resource-per-agent simplicity. Weaknesses: loses admission-time security guarantees, creates race conditions during injection, requires reimplementing a working webhook.

### Key Disagreements Resolved

| Topic | Original | Counter-Proposal | This Design |
|-------|----------|-------------------|-------------|
| Labels | Required on workload for injection | Remove entirely | **Workload label required** for injection (`kagenti.io/inject: enabled`); **workload label** (`kagenti.io/type`) for classification |
| Injection | Mutating webhook | Controller patching | **Webhook** (admission-time, security-first) |
| CR count | 3 pillar CRs | 1 unified CR | **2 CRs**: AgentRuntime + AgentCard |
| Defaults | Per-CR defaults | CR sections optional | **Layered**: cluster → namespace → CR |
| AgentCard | Separate CR | Fold into AgentRuntime | **Separate CR** (different cardinality) |
| Workload targeting | `targetRef` + label selectors | `workloadRef` only | **`targetRef`** (duck typing) + label selectors for AgentCard |

### Motivation

The core thesis from the original proposal remains: **higher-level Kubernetes abstractions that replace standard workload types consistently fail, while composition-based approaches that augment existing workloads succeed**. This design extends that principle with two refinements:

1. **Most agents don't need per-workload CRs.** Layered defaults mean the webhook alone provides a fully functional agent with secure identity. CRs are for exceptions, not the common case.
2. **Identity and observability are tightly coupled to the same workload lifecycle.** They share the same `targetRef`, the same configuration delivery mechanism, and are almost always co-configured. Separate CRs add object count without adding flexibility.

---

## User/User Story

**Platform Engineer**:

- As a platform engineer, I want workloads that explicitly opt in via `kagenti.io/inject: enabled` to automatically receive identity infrastructure at admission time
- As a platform engineer, I want to set cluster-wide and namespace-level defaults for identity and observability so that agents work securely out of the box without per-workload configuration
- As a platform engineer, I want to audit agent runtime configuration with `kubectl get agentruntime -A`

**Application Developer**:

- As a developer, I want to deploy my AI agent using a standard Kubernetes Deployment and opt in to identity infrastructure by adding `kagenti.io/inject: enabled` to my workload labels
- As a developer, I want to classify my workload as an agent or tool using a `kagenti.io/type` label so the Kagenti UI displays it correctly — these two labels are all the Kagenti labels I need to add
- As a developer, I want to override the platform defaults for my specific workload using an AgentRuntime CR when the namespace or cluster defaults don't fit my agent's requirements
- As a developer, I want to expose my agent's capabilities through a standard discovery mechanism by creating an AgentCard CR so other agents can find and invoke it

**Operations Engineer**:

- As an operations engineer, I want comprehensive observability into agent execution configured through defaults that I don't need to repeat per workload
- As an operations engineer, I want to remove Kagenti from a workload without disrupting the workload itself

---

## Goals

1. **Compose with existing Kubernetes workload types** — Never require users to abandon Deployment, StatefulSet, or Job
2. **Minimize per-workload configuration** — Two workload labels (`kagenti.io/inject: enabled` + `kagenti.io/type`) plus layered defaults are all most agents need
3. **Retain labels for workload classification** — The Kagenti UI and ecosystem tooling rely on `kagenti.io/type` labels to identify agents and tools
4. **Provide workload-scoped admission-time identity injection** — Developers explicitly opt workloads in with `kagenti.io/inject: enabled`; opted-in workloads never run without identity infrastructure
5. **Consolidate related concerns** — Identity and observability in one CR; discovery separate
6. **Support dynamic reconfiguration** — Configuration changes without pod restarts where possible; some changes (e.g., modifications to injected sidecar images or init container configuration) may require a pod restart to take effect


---

## Non-Goals

1. **Removing all labels from workloads** — `kagenti.io/inject: enabled` and `kagenti.io/type` labels serve injection opt-in and classification respectively. Developers own both declarations
2. **Replacing the mutating webhook with controller-based injection** — The webhook provides security guarantees that controller patching cannot
3. **Folding AgentCard into AgentRuntime** — Different cardinality model, existing implementation, distinct concern
4. **Building another workload orchestrator** — Users keep their existing orchestration tools
5. **Duplicating existing portfolio functionality** — Secret managers, service meshes, and observability stacks continue to be used

---

## Proposal

### The Two-Layer Architecture (Refined)

```
┌──────────────────────────────────────────────────────────────┐
│ LAYER 1: Automatic Identity Infrastructure                   │
│──────────────────────────────────────────────────────────────│
│ Trigger: workload labeled kagenti.io/inject: enabled         │
│          (required — no workload label, no injection)        │
│                                                              │
│ • Mutating webhook intercepts workload creation              │
│ • Reads layered defaults (cluster → namespace)               │
│ • Injects AuthBridge sidecars with resolved config           │
│ • Agent runs with secure identity immediately                │
│ • No CRs required                                            │
└──────────────────────────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────────┐
│ LAYER 2: Optional Configuration & Discovery                  │
│──────────────────────────────────────────────────────────────│
│ • AgentRuntime CR: Override identity/auth/trace defaults     │
│   - Uses targetRef (duck typing) to reference workload       │
│   - Controller propagates config to sidecars                 │
│   - Pod restarts may be required for some changes            │
│                                                              │
│ • AgentCard CR: Discover agent capabilities                  │
│   - Uses label selector to match pods                        │
│   - Fetches /.well-known/agent.json from agent endpoints     │
│   - Caches cards in CR status                                │
└──────────────────────────────────────────────────────────────┘
```

### Labels: Injection and Workload Classification

Labels serve two distinct purposes on workloads in this architecture:

| Label | Level | Purpose | Set By |
|-------|-------|---------|--------|
| `kagenti.io/inject: enabled` | Workload | **Required** — explicitly opts the workload in to AuthBridge sidecar injection | Developer |
| `kagenti.io/type: agent` or `tool` | Workload | Classifies workload for Kagenti UI and tooling | Developer |

#### Workload-Level Opt-In (Primary Model)

The **primary mechanism** for enabling AuthBridge sidecar injection is an explicit label on the workload itself:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: weather-agent
  labels:
    app: weather-agent
    kagenti.io/inject: enabled    # Opts this workload in to AuthBridge injection
    kagenti.io/type: agent        # Classifies the workload for the Kagenti UI
```

When a workload carries `kagenti.io/inject: enabled`, the mutating webhook intercepts its creation and injects the AuthBridge sidecars. Workloads without this label are never injected, regardless of which namespace they live in.

This model gives developers explicit control: they consciously declare that a workload should receive Kagenti identity infrastructure. There is no ambient injection based on namespace membership.

#### Injection Label Is Required — No Exceptions

If a workload does **not** carry `kagenti.io/inject: enabled`, no sidecar injection occurs. This is a hard requirement. There is no namespace-level override or cluster-wide default that injects sidecars into unlabeled workloads.

#### Why developers must set both labels (addressing the "ownership inversion" argument)

The counter-proposal argued that labels force workload owners to opt into platform concerns. This conflates classification with configuration:

- **Injection** ("this workload should get identity sidecars") is a developer concern. The developer knows whether their workload participates in the Kagenti identity and auth fabric. Explicit opt-in prevents accidental injection of non-agent workloads and makes the intent clear in the workload manifest.
- **Classification** ("this is an agent") is a developer concern. The developer knows what their workload is. A platform engineer should not have to declare that a weather service is an agent. The Kagenti UI requires `kagenti.io/type` to display workloads in the correct category (agent vs. tool).
- **Default configuration** ("use this trust domain, export traces here") is a platform engineer concern. This belongs in namespace/cluster defaults — not in workload labels.
- **Per-workload configuration overrides** are a developer concern. When platform defaults don't fit a specific workload, the developer creates an AgentRuntime CR to override only what needs to change.

Labels handle opt-in and classification (developer-owned). Defaults handle baseline configuration (platform engineer-owned). AgentRuntime CRs handle per-workload overrides (developer-owned). The ownership is clean at every level.

### Layered Defaults

Most agents in a well-configured cluster should not need an AgentRuntime CR. Defaults flow from cluster to namespace to per-workload override:

```
┌─────────────────────────────────────────────────────┐
│ Cluster Defaults                                     │
│ (kagenti-system)                                     │
│                                                      │
│ • SPIFFE trust domain: cluster.local                 │
│ • IdP: keycloak.kagenti-system.svc:8080              │
│ • OTEL endpoint: otel-collector.observability:4317   │
│ • Inbound auth: enabled, port 8080 → 8081            │
│ • Outbound proxy: port 15123, token exchange enabled │
└──────────────────────┬──────────────────────────────┘
                       ↓ (namespace-level overrides)
┌─────────────────────────────────────────────────────┐
│ Namespace Defaults                                   │
│ (in agent namespace)                                 │
│                                                      │
│ • Override trust domain for this namespace            │
│ • Override IdP realm                                 │
│ • Override OTEL endpoint                             │
│ • Override sampling rate                             │
└──────────────────────┬──────────────────────────────┘
                       ↓ (AgentRuntime CR overrides)
┌─────────────────────────────────────────────────────┐
│ Per-Workload Override                                │
│ AgentRuntime CR (optional)                           │
│                                                      │
│ • Override specific fields for this workload         │
│ • Only needed when defaults don't fit                │
└─────────────────────────────────────────────────────┘
```

**Resolution order**: The webhook merges configuration in order: cluster defaults → namespace defaults → AgentRuntime CR (if exists). The merged configuration is used at injection time to configure sidecars. When defaults or CRs change post-injection, the operator propagates updates to running sidecars (see [Configuration Propagation](#configuration-propagation-open-design) below).

**Default Values** (representative, not exhaustive):

| Category | Setting | Default |
|----------|---------|---------|
| Identity | SPIFFE trust domain | `cluster.local` |
| Identity | SPIFFE socket path | `unix:///run/spire/agent-sockets/agent.sock` |
| Identity | IdP provider | Keycloak |
| Identity | IdP URL | `http://keycloak.kagenti-system.svc:8080` |
| Identity | IdP realm | `default` |
| Identity | Inbound auth port | `8080` → `8081` |
| Identity | Outbound proxy port | `15123` |
| Identity | Token exchange default audience | `downstream-service` |
| Trace | OTEL endpoint | `otel-collector.observability:4317` |
| Trace | OTEL protocol | `grpc` |
| Trace | Sampling type | `probabilistic` |
| Trace | Sampling rate | `0.1` |

Namespace-level defaults override cluster defaults for any setting. The specific storage mechanism for defaults (ConfigMap, CRD, or other) is an implementation detail to be determined.

### AgentRuntime CR

**Purpose**: Override layered defaults for a specific workload's identity and observability configuration.

**Owner**: The developer. Platform engineers set the defaults; developers create an AgentRuntime CR when those defaults need to be adjusted for a specific workload.

**When to create one**: Only when cluster/namespace defaults don't fit a specific workload. Most agents won't need this.

**API Structure**:

```yaml
apiVersion: kagenti.io/v1alpha1
kind: AgentRuntime
metadata:
  name: weather-agent-runtime
  namespace: default
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: weather-agent

  # Identity configuration (overrides defaults)
  identity:
    spiffe:
      trustDomain: "prod.cluster.local"

    clientRegistration:
      provider: keycloak
      keycloak:
        url: "http://keycloak-prod.auth.svc:8080"
        realm: "production"
        adminCredentialsSecret: "keycloak-prod-admin"
        clientNameTemplate: "agent-{{.PodName}}"
        tokenExchangeEnabled: true

    inbound:
      port: 8080
      targetPort: 8081
      validation:
        issuer: "http://keycloak-prod.example.com/realms/production"
        jwksUrl: "http://keycloak-prod.auth.svc:8080/realms/production/certs"
        audience: "self"
        requiredScopes:
        - "agent:invoke"
        - "agent:stream"

    outbound:
      trafficInterception:
        proxyPort: 15123
        proxyUid: 1337
        excludePorts:
        - 8080
        - 9901
      tokenExchange:
        tokenUrl: "http://keycloak-prod.auth.svc:8080/realms/production/protocol/openid-connect/token"
        defaultTarget:
          audience: "downstream-service"
          scopes:
          - "downstream:access"
        destinationRules:
        - match:
            host: "premium-api.external.com"
          target:
            audience: "premium-api"
            scopes:
            - "weather:premium"
            - "weather:historical"

  # Observability configuration (overrides defaults)
  trace:
    exporters:
    - type: otlp
      endpoint: "otel-collector.observability:4317"
      protocol: grpc
      compression: gzip
    - type: jaeger
      endpoint: "jaeger-collector.observability:14250"

    sampling:
      type: probabilistic
      rate: 0.5

    genai:
      enabled: true
      capturePrompts: true
      captureCompletions: true
      captureModelParameters: true

    resourceAttributes:
      service.name: "weather-agent"
      service.version: "2.1.0"
      deployment.environment: "production"

    integration:
      mlflow:
        enabled: true
        trackingUri: "http://mlflow.ml-platform:5000"
        experimentName: "weather-agent-prod"
      prometheus:
        enabled: true
        port: 9090
        path: "/metrics"

status:
  phase: Active
  message: "Runtime configured"
  configuredPods: 2
  identity:
    spiffeEnabled: true
    idpRegistered: true
    inboundProxyReady: true
    outboundProxyReady: true
  trace:
    exportersConfigured: 2
    samplingRate: 0.5
```

**Controller Behavior**:
1. Watches AgentRuntime CRs for create/update/delete
2. Resolves `targetRef` to find workload (duck typing — works with Deployment, StatefulSet, Job, CronJob)
3. Merges CR spec with cluster/namespace defaults
4. Propagates merged configuration to running sidecars (see [Configuration Propagation](#configuration-propagation-open-design))
5. Updates CR status with identity and observability state

### AgentCard CR (Unchanged)

AgentCard remains a separate CR. It is reproduced here for completeness but is not modified from the original proposal.

**Why separate**:
- **Different cardinality**: AgentCard uses a label selector (can match multiple pods across workloads). AgentRuntime uses `targetRef` (1:1 with a workload). Forcing these into one CR would require supporting both targeting models in one resource.
- **Different concern**: Discovery ("what can agents do") is distinct from runtime ("how are agents configured"). The name `AgentRuntime` does not naturally encompass capability discovery.
- **Existing implementation**: Code exists and works. Refactoring it into a subsection of another CR is churn without benefit.

**API Structure**:

```yaml
apiVersion: kagenti.io/v1alpha1
kind: AgentCard
metadata:
  name: weather-agent-card
  namespace: default
spec:
  syncPeriod: "30s"
  selector:
    matchLabels:
      app: weather-agent
      kagenti.io/type: agent
status:
  protocol: "a2a"
  lastSyncTime: "2026-01-21T10:30:00Z"
  conditions:
  - type: Synced
    status: "True"
    lastTransitionTime: "2026-01-21T10:30:00Z"
    reason: SyncSuccess
    message: "Agent card successfully fetched"
  card:
    name: "Weather Intelligence Agent"
    description: "Provides weather forecasts and current conditions"
    version: "2.1.0"
    url: "http://weather-agent.default.svc.cluster.local:8080"
    capabilities:
      streaming: true
      pushNotifications: false
    defaultInputModes:
    - "application/json"
    - "text/plain"
    defaultOutputModes:
    - "application/json"
    skills:
    - name: "get_forecast"
      description: "Get weather forecast for a location"
      inputModes:
      - "application/json"
      outputModes:
      - "application/json"
      parameters:
      - name: "location"
        type: "string"
        description: "City name or coordinates (lat,lon)"
        required: true
      - name: "days"
        type: "number"
        description: "Number of days to forecast (1-14)"
        required: false
        default: "7"
```

### Cardinality: 1:1 Between AgentRuntime and Workload

The `targetRef` pattern establishes a 1:1 relationship between an AgentRuntime CR and a workload. This is intentional and should not be relaxed.

**Why 1:1 is correct**:
- **Auditability**: `kubectl get agentruntime -A` shows exactly which workloads have custom configuration
- **Proven pattern**: KEDA ScaledObject, Flagger Canary, and cert-manager Certificate all use 1:1 `targetRef`
- **Clear ownership**: One CR configures one workload — no ambiguity about which configuration applies

**Addressing the fleet concern**: The counter-proposal implicitly raised the concern that 50 identical agents would need 50 identical AgentRuntime CRs. Layered defaults solve this:

| Scenario | What the developer creates | AgentRuntime CR needed? |
|----------|---------------------------|------------------------|
| Standard agent | Deployment + `kagenti.io/inject: enabled` + `kagenti.io/type` | No |
| Agent in a namespace with custom IdP realm | Deployment + `kagenti.io/inject: enabled` + `kagenti.io/type` | No (namespace defaults) |
| Agent needing custom token exchange rules | Deployment + `kagenti.io/inject: enabled` + `kagenti.io/type` + AgentRuntime | Yes |
| Fleet of 50 identical agents | 50 Deployments + `kagenti.io/inject: enabled` + `kagenti.io/type` | No (defaults cover them) |
| Workload without `kagenti.io/inject: enabled` | No injection occurs, regardless of namespace | N/A |

**The 1:1 constraint is not a burden on developers** because most developers will never create an AgentRuntime CR. Namespace-level defaults handle the common case. When defaults do not fit a specific workload, the developer creates an AgentRuntime CR to override only the fields that differ — this is a developer-owned resource, not a platform engineer concern.

### Mutating Webhook Design

The mutating webhook from the original proposal is retained. While the counter-proposal's suggestion to use controller-based injection raises valid points worth acknowledging, the webhook approach remains the preferred path for the following reasons:

**Why keep the webhook**:

1. **Security guarantee**: The webhook injects at admission time. A pod is **never created** without identity sidecars. Controller-based patching introduces a race window where pods run without identity infrastructure — unacceptable for a security-first platform.
2. **Already implemented**: The webhook exists and functions. Replacing it is a rewrite with no functional benefit.
3. **Proven pattern**: Every major service mesh (Istio, Linkerd) and secrets manager (Vault Agent) uses admission-time injection for the same security reasons.
4. **Complementary to the operator**: The webhook handles injection. The operator handles reconfiguration. These are different concerns at different lifecycle stages.

**Webhook Configuration**:

The webhook currently targets workload objects (`deployments`and `statefulsets`) directly. This means the pod template inside those objects is mutated at admission time. This approach has a known conflict with GitOps CD pipelines — see [Long-Term: pod-level injection](#long-term-future-enhancements) for the planned migration to `pods`-targeted injection.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: kagenti-injector
webhooks:
- name: inject.kagenti.io
  clientConfig:
    service:
      name: kagenti-operator
      namespace: kagenti-system
      path: /mutate
    caBundle: ${CA_BUNDLE}
  rules:
  - operations: ["CREATE", "UPDATE"]
    apiGroups: ["apps"]
    apiVersions: ["v1"]
    resources: ["deployments", "statefulsets", "daemonsets"]
  - operations: ["CREATE", "UPDATE"]
    apiGroups: ["batch"]
    apiVersions: ["v1"]
    resources: ["jobs", "cronjobs"]
  objectSelector:
    matchExpressions:
    - key: kagenti.io/inject
      operator: In
      values: ["enabled"]
  admissionReviewVersions: ["v1"]
  sideEffects: None
  timeoutSeconds: 10
  failurePolicy: Fail
  reinvocationPolicy: Never
```

> **Note**: The webhook's `objectSelector` is the sole gate for injection. Only workloads explicitly labeled `kagenti.io/inject: enabled` trigger the webhook. A workload without this label is never injected — regardless of which namespace it lives in.

**Webhook Injection Decision Logic**:

```
Is workload labeled kagenti.io/inject: enabled?
  ├─ YES → Inject sidecars
  └─ NO  → No injection (hard requirement, no exceptions)
```

**Webhook Behavior**:

1. Intercepts workload creation/update **only** when the workload carries `kagenti.io/inject: enabled`
2. Reads cluster defaults from `kagenti-system`
3. Reads namespace defaults from workload namespace (if exists)
4. Checks for an AgentRuntime CR targeting this workload (if exists)
5. Merges configuration: cluster → namespace → CR
6. Injects AuthBridge sidecars with merged configuration
7. Annotates workload with `kagenti.io/injected-at` timestamp and config hash

**Injected Components (Current)**:

| Component | Type | Purpose |
|-----------|------|---------|
| `proxy-init` | Init Container | Sets up iptables for traffic interception |
| `spiffe-helper` | Sidecar | Manages SPIFFE workload identity |
| `client-registration` | Sidecar | Registers agent with identity provider |
| `envoy-proxy` | Sidecar | Intercepts outbound traffic, performs token exchange |

> **Note: AuthBridge Sidecar Consolidation** — The current AuthBridge implementation uses multiple sidecars as listed above. The Kagenti team plans to consolidate these into fewer containers in the near term. The current multi-sidecar design reflects the initial implementation where each concern was developed independently. Consolidation will reduce per-pod resource overhead, simplify configuration propagation (fewer processes to update), and reduce pod startup latency. The architecture described in this proposal is designed to work with both the current multi-sidecar layout and the future consolidated form — the webhook injects whatever the current AuthBridge implementation requires, and the number of injected containers is an implementation detail transparent to the developer.

### Controller Architecture

The webhook and the operator run as independent pods. The webhook handles admission-time injection; the operator handles post-admission reconciliation.

```
┌────────────────────────────────────────────────────────┐
│ Kagenti Webhook Pod (kagenti-webhook-system)           │
│                                                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │ Webhook Server                                   │  │
│  │  • Handles mutation requests at admission time   │  │
│  │  • Injects AuthBridge sidecars                   │  │
│  │  • Validates AgentRuntime CRs                    │  │
│  └──────────────────────────────────────────────────┘  │
│                                                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │ Defaults Watcher                                 │  │
│  │  • Watches cluster/namespace defaults (ConfigMaps│  │
│  │  • Reloads defaults when ConfigMaps change       │  │
│  └──────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────┐
│ Kagenti Operator Pod                                   │
│                                                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │ Controller Manager                               │  │
│  │                                                  │  │
│  │  • AgentRuntime Reconciler                       │  │
│  │    - Resolves targetRef (duck typing)            │  │
│  │    - Merges with layered defaults                │  │
│  │    - Propagates config to running sidecars       │  │
│  │    - Updates CR status                           │  │
│  │                                                  │  │
│  │  • AgentCard Reconciler                          │  │
│  │    - Discovers agent capabilities via selector   │  │
│  │    - Fetches /.well-known/agent.json             │  │
│  │    - Caches cards in CR status                   │  │
│  │                                                  │  │
│  │  • Shared Utilities                              │  │
│  │    - targetRef resolver (duck typing)            │  │
│  │    - Configuration propagation                   │  │
│  │    - Status updater                              │  │
│  │    - Defaults merger                             │  │
│  └──────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────┘
```

### Configuration Propagation (Open Design)

A key requirement of the architecture is that configuration changes (whether to cluster/namespace defaults or to an AgentRuntime CR) must propagate efficiently to running identity, security, and observability sidecars **without requiring pod restarts where possible**. Some changes — such as modifications to sidecar container images or init container configuration — inherently require a pod restart.

The specific mechanism for this propagation is still under discussion. The candidates include:

| Mechanism | Pros | Cons |
|-----------|------|------|
| **xDS (Envoy discovery service)** | Sub-second propagation; native to Envoy proxy; proven at scale by Istio/Envoy ecosystem; supports streaming updates | Requires xDS control plane; only directly applicable to Envoy-based sidecars |
| **ConfigMap volume mounts** | Simple; native Kubernetes; no additional infrastructure | Kubelet sync period introduces lag (default ~60s, configurable); not suitable for latency-sensitive security updates |
| **gRPC streaming from operator** | Low latency; flexible; works for all sidecar types | Custom protocol; additional complexity |
| **Watch-based (sidecar watches K8s API)** | Real-time updates; no intermediary | Increases API server load at scale; requires RBAC for each sidecar |

**Current assessment**: For the Envoy proxy sidecar (which handles outbound token exchange and traffic interception), **xDS is the leading candidate** — it is Envoy's native configuration interface and provides the low-latency updates required for security-sensitive configuration like token exchange rules and destination policies. For other sidecars (spiffe-helper, auth-proxy, client-registration), the propagation mechanism may differ and will be determined during implementation.

**Requirements regardless of mechanism**:
- Configuration changes should reach running sidecars without pod restarts where possible; changes to sidecar images or init containers require a pod restart
- Identity and security configuration updates must propagate with low latency (target: seconds, not minutes)
- Observability configuration updates are less latency-sensitive but should avoid pod restarts where possible
- The operator must be able to verify that propagation has completed and report status

This is an active area of design. The choice of propagation mechanism will be finalized during Phase 1 implementation.

### Agent Code Requirements

#### Telemetry Instrumentation

It is the developer's responsibility to instrument their agent code with the OpenTelemetry SDK.

**Configuration Source**: Configuration is provided to agent code by the platform (delivery mechanism TBD — see [Configuration Propagation](#configuration-propagation-open-design)). Agent code reads OTEL configuration from environment variables or a configuration file provided at a well-known path.

**Minimal Example**:

```python
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
import os

def setup_telemetry():
    # OTEL endpoint provided by Kagenti platform via environment or config
    endpoint = os.getenv('OTEL_EXPORTER_OTLP_ENDPOINT',
                         'otel-collector.observability:4317')

    provider = TracerProvider()
    exporter = OTLPSpanExporter(endpoint=endpoint, insecure=True)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)

    return trace.get_tracer(__name__)

tracer = setup_telemetry()

with tracer.start_as_current_span("tool_execution"):
    result = execute_tool()
```

#### Agent Card Endpoint

Agent code must expose a capability card for the AgentCard controller.

**Endpoint**: `/.well-known/agent.json` on agent port (8081)

**Minimal Example**:

```python
from flask import Flask, jsonify

app = Flask(__name__)

@app.route('/.well-known/agent.json')
def agent_card():
    return jsonify({
        "name": "Weather Intelligence Agent",
        "version": "2.1.0",
        "capabilities": {
            "streaming": True,
            "batchProcessing": True
        },
        "skills": [
            {
                "name": "get_forecast",
                "description": "Get weather forecast"
            }
        ]
    })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8081)
```

---



### After (Composition — Custom Configuration Needed)

```yaml
# Standard Kubernetes Deployment with explicit injection opt-in
apiVersion: apps/v1
kind: Deployment
metadata:
  name: weather-agent
  namespace: team1
  labels:
    app: weather-agent
    kagenti.io/inject: enabled
    kagenti.io/type: agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: weather-agent
  template:
    metadata:
      labels:
        app: weather-agent
    spec:
      containers:
      - name: agent
        image: "ghcr.io/example/weather-agent:v1"
        ports:
        - containerPort: 8081
---
# AgentRuntime — only needed to override defaults
apiVersion: kagenti.io/v1alpha1
kind: AgentRuntime
metadata:
  name: weather-agent-runtime
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: weather-agent
  identity:
    outbound:
      tokenExchange:
        destinationRules:
        - match:
            host: "premium-api.external.com"
          target:
            audience: "premium-api"
            scopes:
            - "weather:premium"
  trace:
    sampling:
      rate: 1.0  # full sampling for this agent
---
# AgentCard — optional, for discovery
apiVersion: kagenti.io/v1alpha1
kind: AgentCard
metadata:
  name: weather-agent-card
spec:
  selector:
    matchLabels:
      app: weather-agent
  syncPeriod: 30s
```

---

## Impacts / Key Questions

### Pattern Comparison

| Aspect | Inheritance (Agent CR) | Original (3 Pillar CRs) | Counter (AgentRuntime only) | This Design |
|--------|----------------------|-------------------------|---------------------------|-------------|
| Objects per agent | 1 | 1-4 | 2 | 1-3 (usually 1) |
| Labels needed | No | Yes (injection + type) | No | `kagenti.io/inject: enabled` + `kagenti.io/type` on workload |
| Webhook | No | Yes | No | Yes |
| Admission-time security | No | Yes | No (race window) | Yes |
| Workload modification | Yes (replaced) | Yes (injection label) | No | Minimal (two labels only) |
| Per-workload CR required | Always | Optional | Always | Optional |
| Auditability | `kubectl get agent` | Mixed | `kubectl get agentruntime` | Workload labels + CRs |
| Fleet configuration | N/A | Per-workload CRs | Per-workload CRs | Layered defaults |

### Open Questions

1. **Defaults storage mechanism**: How should cluster and namespace defaults be stored and managed? (ConfigMap, dedicated CRD, or other)
2. **Configuration propagation mechanism**: How should configuration updates reach running sidecars? (See [Configuration Propagation](#configuration-propagation-open-design))
3. **AgentRuntime CR lifecycle**: Should deleting an AgentRuntime CR revert to defaults or remove configuration entirely?
4. **Injection trigger mechanism — label vs CR** *(unresolved, more discussion needed)*: The current design uses a workload label (`kagenti.io/inject: enabled`) as the sole trigger for AuthBridge injection. An alternative is to use the existence of an `AgentRuntime` CR targeting a workload as the injection trigger, eliminating the need for the label entirely. Each approach has trade-offs that have not yet been fully evaluated:

   **Label-trigger (current)**:

   ```yaml
   # Workload carries the injection label
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: weather-agent
     labels:
       kagenti.io/inject: enabled
       kagenti.io/type: agent
   ```

   Simple and GitOps-friendly — no CR required for basic injection. Developer adds a label; the webhook injects sidecars. Downside: injection and configuration are decoupled — a workload can be injected without any AgentRuntime CR, relying entirely on defaults. There is an architectural tension: a label on the workload contradicts the goal that platform engineers should be able to configure identity policies centrally without modifying agent workload manifests.

   **CR-trigger (alternative)**:

   ```yaml
   # Workload is completely clean — no Kagenti labels
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: weather-agent
   ---
   # AgentRuntime CR is the single source of truth for injection + configuration
   apiVersion: kagenti.io/v1alpha1
   kind: AgentRuntime
   metadata:
     name: weather-agent-runtime
     namespace: team1
   spec:
     workloadRef:
       apiVersion: apps/v1
       kind: Deployment
       name: weather-agent
     identity:
       enabled: true
     trace:
       exporters: []
     card:
       syncPeriod: "30s"
   ```

   The AgentRuntime CR is the single source of truth for both injection and configuration. The referenced Deployment remains clean with no Kagenti labels. Auditability is improved — `kubectl get agentruntime -A` shows all platform-managed workloads without label scanning. This follows the same composition-over-inheritance principle already used by KEDA, Flagger, and cert-manager. Downside: every workload needing injection must have an AgentRuntime CR; the webhook must watch for CR existence rather than (or in addition to) workload admission labels, which is architecturally more complex.

   **Implementation paths for CR-trigger**:
   - *Controller-based*: A controller patches workloads when an AgentRuntime CR is created — no webhook label check required, but loses admission-time security guarantees (pods can run briefly without sidecars).
   - *CR-aware webhook*: The webhook queries for an AgentRuntime CR at admission time instead of checking a label — retains the admission-time security guarantee while eliminating the workload label requirement.

   **Historical note**: Istio's label-based injection model (namespace and pod-level labels controlling injection) has been a known source of operational complexity — namespace/pod-level conflicts, audit difficulty, and accidental injection gaps. This precedent is relevant context for this decision.

   This decision affects the webhook design, the developer experience, and how defaults interact with explicit configuration. Agreement on the preferred approach is needed before this section is finalized.

### Pros

1. **Explicit developer intent**: Developers consciously opt workloads in with `kagenti.io/inject: enabled` — no accidental injection, clear manifest ownership
2. **Secure by default**: Webhook ensures agents never run without identity infrastructure
3. **Platform engineer friendly**: Defaults set once, override only when needed
4. **Low object count**: 1 object (Deployment) for common case, up to 3 for full customization
5. **Proven patterns**: Webhook injection, duck-typed targetRef, layered defaults
6. **Clean separation**: AgentRuntime for runtime config, AgentCard for discovery
7. **Incremental adoption**: Namespace label → type label → defaults → AgentRuntime CR → AgentCard, each step optional
8. **Multi-workload support**: Deployments and StatefulSets all work

### Cons

1. **Two labels required**: Developers must add both `kagenti.io/inject: enabled` and `kagenti.io/type` to workloads — minimal burden, but not zero
2. **Webhook dependency**: If webhook is unavailable, workload creation blocks (mitigated by replicas)
3. **Defaults complexity**: Three-layer merge adds implementation complexity
4. **Two CRs still needed for full functionality**: AgentRuntime + AgentCard remain separate resources
5. **CD tooling drift (current design limitation)**: The webhook currently targets `Deployment`, `StatefulSet`, and similar workload objects directly. When the webhook mutates the pod template spec inside a Deployment at admission time, GitOps CD tools (Argo CD, Flux) detect a diff between the live object and the Git-stored manifest and report it as configuration drift — producing false-positive alerts or actively reverting the injected sidecars on the next sync. This is a known limitation of the current workload-level targeting approach. The long-term fix (targeting `pods` instead of workload objects) eliminates the drift entirely because pod objects are ephemeral and not tracked by CD tools. See [Long-Term Enhancements](#long-term-future-enhancements).

---

## Risks and Mitigations

### Risk 1: Webhook Availability

**Risk**: If the mutating webhook is unavailable, agent workloads fail to create.

**Mitigation**:
- Deploy webhook with multiple replicas
- Use PodDisruptionBudgets
- Fail-closed is intentional (security-first approach)
- Webhook health monitoring and alerting

### Risk 2: Configuration Propagation Latency

**Risk**: Changes to defaults or AgentRuntime CRs may not propagate to running sidecars quickly enough.

**Mitigation**:
- Configuration propagation mechanism is being evaluated (see [Configuration Propagation](#configuration-propagation-open-design))
- xDS-based propagation (used by Envoy) provides sub-second updates as a candidate approach
- Operator monitors propagation state and reports drift in CR status
- Health checks verify configuration state matches expected defaults


### Risk 3: Multiple Webhook Ordering Conflicts

**Risk**: Kubernetes clusters running multiple mutating admission webhooks (e.g., Istio sidecar injection, Vault Agent injector, and the Kagenti AuthBridge injector simultaneously) can encounter subtle ordering failures. Kubernetes does not guarantee a deterministic execution order among webhooks within the same `failurePolicy` tier. If one webhook's mutation overwrites or conflicts with another's — for example, both modifying the pod's `initContainers` list or `volumes` — the result depends on execution order, which can vary across API server restarts or cluster upgrades. This produces failures that are intermittent, environment-specific, and hard to reproduce.

**Mitigation**:
- Set `reinvocationPolicy: IfNeeded` on the Kagenti webhook so Kubernetes re-invokes it if a later webhook mutates the object — giving Kagenti a chance to reconcile any overwritten fields
- Document which container names and volume names the Kagenti webhook uses so operators can identify and resolve conflicts with other webhooks
- Test explicitly in environments where Istio ambient or sidecar mode is also active, as this is the most common co-tenant webhook
- The long-term migration to pod-level injection (see [Long-Term Enhancements](#long-term-future-enhancements)) reduces the conflict surface by narrowing the webhook's scope to pod admission only, matching the pattern used by Istio and other well-established injectors

### Risk 4: Identity Infrastructure Overhead

**Risk**: Injected sidecars add resource overhead and latency.

**Mitigation**:
- Annotations allow disabling specific components
- Sidecar resource limits are configurable via defaults and AgentRuntime CR
- Token caching reduces token exchange latency

### Security Considerations

Unchanged from original proposal:

- **SPIFFE** provides cryptographic workload identity
- **IdP registration** provides OAuth2/OIDC tokens
- **Token validation** at inbound proxy (auth-proxy)
- **Token exchange** at outbound proxy (envoy-proxy)
- **Network policies** restrict traffic flows
- **Fail-closed webhook** ensures agents never run without identity
- **TLS certificates** managed by cert-manager with automatic rotation
- **Secret management** via Kubernetes Secrets with recommendation for external managers (Vault, External Secrets Operator)

---

## Implementation Phases

**Phase 1: AgentRuntime CR + Layered Defaults** (Q1 2026)
- Define AgentRuntime CRD (consolidating TokenExchange + AgentTrace)
- Implement layered defaults mechanism (cluster → namespace)
- Implement AgentRuntime controller with targetRef resolution
- Update existing webhook to read layered defaults
- Validate with Deployment, StatefulSet, Job workload types

**Phase 2: Observability Maturation** (Q2 2026)
- Refine AgentTrace section of AgentRuntime based on OTEL GenAI semantic conventions
- Integrate with observability stack (MLflow, Phoenix)
- Partner with observability team for feedback


---

## Success Metrics

1. **Adoption Rate**: Percentage of agent workloads using composition pattern vs. legacy Agent CR
2. **Time to First Agent**: Time from `kubectl apply` of a labeled Deployment to a working agent with identity (target: <30s)
3. **CR-Free Ratio**: Percentage of agents running with defaults only (no AgentRuntime CR) — higher is better
4. **Configuration Change Latency**: Time from defaults/CR update to sidecar reconfiguration (target: seconds, not minutes — dependent on propagation mechanism)
5. **Removal Impact**: Zero workload disruption when Kagenti is removed

---

## References

### Prior Proposals
- [Compositional Agent Platform Architecture](compositional-agent-platform-design.md) — Original three-pillar proposal
- [Label-based injection versus using a reference CR pattern](https://hackmd.io/ci9bS5pYScKFfNBW0wfW1Q) — Counter-proposal for AgentRuntime CR

### Successful Composition Projects
- KEDA — Event-driven autoscaling (ScaledObject with targetRef)
- Flagger — Progressive delivery (Canary with targetRef)
- Prometheus Operator — Monitoring (ServiceMonitor with selector)
- cert-manager — Certificate management (Certificate with targetRef)

### Pattern References
- Knative pkg duck-typing — Duck-typing utilities
- RFC 8693 — OAuth 2.0 Token Exchange
- OpenTelemetry GenAI Semantic Conventions

---

*Document consolidates proposals from Kagenti Team and Roland Huss, authored with assistance from Claude Opus 4.6.*
