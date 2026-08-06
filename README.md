# k8s_ArgoCD — Platform Documentation

GitOps repository for a **hub/spoke Kubernetes platform** on self-hosted EC2, driven
entirely by ArgoCD (App-of-Apps + ApplicationSets). This document is a from-scratch
map of the repo: topology, deployment model, wave ordering, and each subsystem.

---

## 1. Topology: Hub and Spokes

| Cluster role | What it runs | Notes |
|---|---|---|
| **Hub** | ArgoCD itself, cluster-mesh CA root, the self-hosted IRSA equivalent (pod-identity-webhook), and (as of the "observability re-split") the **entire fleet-wide observability backend**: Prometheus (full, with remote-write receiver), Grafana, Alertmanager, Loki, Tempo | Only one hub exists. ArgoCD manages every spoke from here. |
| **Spoke(s)** | Application workloads (`fastapi-app`, `postgresql`), and thin platform infra: Cilium, cert-manager, KEDA, CNPG operator, Karpenter (controller + per-spoke NodePool/EC2NodeClass), OTel **DaemonSet only** (no local aggregator), Prometheus in **Agent mode** (no local TSDB/Grafana), pod-identity-webhook | Currently one spoke: `spoke-dev-k8s`. Onboarding a new spoke = drop a file in `argocd/clusters/`. |

Clusters are connected via **Cilium Cluster Mesh** (shared root CA, `clustermesh-ca-issuer`),
which lets a spoke resolve a Service name (e.g. `monitoring-hub-prometheus`,
`otel-collector-agg-collector-mesh`) and transparently reach **hub's real pods** —
no manual IP/DNS/NLB wiring required.

### Why the observability re-split happened
Originally every spoke ran its own full Prometheus/Grafana/Loki/Tempo. The repo was
restructured so:
- **Hub** = single source of truth for metrics/logs/traces (Prometheus with `remoteWrite`
  receiver enabled, Grafana, Loki, Tempo — all backed by EBS via `ebs-csi` StorageClass).
- **Spoke** = Prometheus Agent mode (no query API, just scrapes + `remote_write`s to hub)
  and OTel DaemonSet only (forwards to hub's aggregator over Cluster Mesh).
- This introduces a **real runtime coupling**: spoke KEDA autoscaling and spoke Grafana
  dashboards now depend on hub being reachable. If hub goes down, KEDA triggers are
  ignored (not scaled to zero/max — `ignoreNullValues: true`), not fatal.

---

## 2. Repo Layout

```
argocd/
  clusters/            # ExternalSecret per spoke — registers it with ArgoCD (role=spoke)
  projects/            # AppProject definitions (RBAC / repo & destination allow-lists)
  root-apps/           # App-of-Apps entrypoints (root-hub, root-spokes, root-clusters)
  hub/                 # Applications that run ONLY on hub (wave-numbered filenames)
  spokes/
    infra/             # ApplicationSets fanned out to every spoke (platform infra)
    workloads/         # ApplicationSets fanned out to every spoke (app workloads)

platform/
  values/{base,hub,spoke}/   # Helm values, layered: base (shared) + tier overlay (wins)
  charts/otel/                # Custom local chart: OTel Collector (DaemonSet + Deployment)
  karpenter/spoke/             # Custom local chart: Karpenter NodePool + EC2NodeClass (per-spoke)
  gateway-api/                 # Gateway + GatewayClass manifests (replaces ingress-nginx)
  gateway-routes/{hub,spoke}/ # HTTPRoutes per cluster tier
  clustermesh/{common,hub,spoke}/  # Shared CA generation/distribution for Cluster Mesh
  cert-manager/                # ClusterIssuer bootstrap (self-signed internal root)
  external-secrets-config/    # ClusterSecretStore for spoke registration
  webhook-guards/              # PreSync hook Job that blocks IRSA-dependent controllers
                                # until pod-identity-webhook is actually Running
  monitoring-configs/          # Plain manifests, ONE SUBDIR PER OWNING APPLICATION:
    cilium/                       # Cilium/Hubble ServiceMonitors
    mesh/                         # Hub-Prometheus Cluster Mesh placeholder Service
    README.md                     # explains the one-subdir-per-owner rule (don't violate it)
  grafana-dashboards/          # ConfigMaps auto-picked up by Grafana sidecar

services/
  fastapi-app/          # Local Helm chart: the application workload
  postgresql/            # Local Helm chart: CloudNativePG Cluster + PgBouncer poolers

.github/workflows/
  validate.yml           # helm lint + template + Trivy scan on every PR
  (clustermesh-sync.yml referenced — regenerates cilium.yaml's cluster peer list)
```

---

## 3. GitOps Mechanics

### App-of-Apps entrypoints (`argocd/root-apps/`)
- **`root-hub.yaml`** → points at `argocd/hub/`, applied by hand once (bootstrap).
- **`root-spokes.yaml`** → points at `argocd/spokes/`, applies every ApplicationSet.
- **`root-clusters.yaml`** → points at `argocd/clusters/`, one ExternalSecret per spoke.

### Spoke registration flow
1. A spoke is provisioned (Terraform, outside this repo) and runs a
   `register-with-hub.sh.tpl` script that pushes `{name, role, server, token, caData}`
   to AWS Secrets Manager under `argocd-clusters/<name>`.
2. `argocd/clusters/<name>.yaml` (an `ExternalSecret`) pulls that back down and
   materializes an ArgoCD cluster Secret labeled `cluster-role: workload`, plus static
   `cluster-mesh-id`/`cluster-mesh-ip` labels and IRSA role-arn annotations
   (`irsa-ebs-csi-role-arn`, `irsa-external-secrets-role-arn`) consumed by
   the relevant ApplicationSets' `helm.parameters`.
3. Every ApplicationSet under `argocd/spokes/**` uses a `clusters` generator selecting
   `cluster-role: workload` — so one new file with those static labels/annotations is the
   **entire manual step** for onboarding.
4. A GitHub Action (`clustermesh-sync.yml`) regenerates
   `platform/values/base/cilium.yaml`'s peer list from every `argocd/clusters/*.yaml`.

### Values layering convention (base + tier)
Every shared chart follows: `platform/values/base/<chart>.yaml` (identical across tiers)
+ `platform/values/{hub,spoke}/<chart>.yaml` (tier-specific override, applied last so it
wins). Empty `{}` tier files are placeholders, not evidence of a bug — see
`platform/values/spoke/cert-manager.yaml` for the pattern. Do **not** hand-edit `base/`
to special-case one tier.

### Sync-wave ordering
Every ArgoCD `Application`/`ApplicationSet` carries
`argocd.argoproj.io/sync-wave: "<N>"`. Lower numbers sync first. Actual current chains
(verified against the manifests, not aspirational):

**Spoke chain** (`argocd/spokes/infra/` + `argocd/spokes/workloads/`):

```
00  gateway-api-crds
10  aws-ccm, cilium
20  cert-manager, cnpg-operator, karpenter, gateway-class
30  metrics-server, keda, cert-manager-configs, clustermesh-ca, gateway,
    karpenter-nodepool
40  pod-identity-webhook, opentelemetry-operator, gateway-routes
50  aws-ebs-csi-driver, external-secrets, otel-collectors (DaemonSet)
60  kube-prometheus-stack (agent), postgresql
70  cilium-servicemonitors, hub-prometheus-mesh-service, fastapi-app
```

**Hub chain** (`argocd/hub/`):

```
00  gateway-api-crds
10  argocd, cilium, aws-ccm
20  cert-manager, gateway-class, opentelemetry-operator
30  gateway, cert-manager-configs, metrics-server, clustermesh-ca
40  gateway-routes, pod-identity-webhook
50  aws-ebs-csi-driver, external-secrets, tempo, loki, otel-collectors (aggregator)
60  external-secrets-config, kube-prometheus-stack
70  observability-routes, grafana-dashboards, cilium-servicemonitors
```

Note: `aws-ebs-csi-driver` and `external-secrets` were **bumped from wave 20 to wave 50**
on both tiers once their controllers moved to IRSA (via `pod-identity-webhook`, wave 40) —
admission mutation only happens once, at pod creation, so the webhook must already be
serving before those controller pods are first created. A `platform/webhook-guards/`
PreSync hook Job enforces this at the cluster level in case wave ordering alone races on
a from-scratch bootstrap; don't rely on wave numbers as the only guarantee for that pair.

CI (`validate.yml`) renders every local chart with `--api-versions` flags matching this
list, specifically so CRD-gated resources (ServiceMonitor, ScaledObject, Cluster,
Pooler, OpenTelemetryCollector, Instrumentation) don't silently render to nothing.

---

## 4. Networking

- **CNI**: Cilium, **native routing mode** (no VXLAN), ENI IPAM with prefix delegation,
  `kubeProxyReplacement: true`, WireGuard encryption, `identityAllocationMode: crd`.
  AWS CCM's route controller is run with `--configure-cloud-routes=false` — pod IPs are
  now real VPC-routable ENI secondary IPs, so no per-node podCIDR route sync is needed.
- **Ingress**: `ingress-nginx` has been fully replaced by **Gateway API** (Cilium's
  embedded Envoy). One shared `Gateway` per cluster (`hub-gateway`, `spoke-gateway`),
  each app attaches an `HTTPRoute` to a named listener. AWS CCM auto-provisions one NLB
  per Gateway via the Cilium-generated `LoadBalancer` Service. The `cilium` GatewayClass
  is explicitly managed (not Cilium's auto-created one) so JSON access logging can be
  attached via `CiliumGatewayClassConfig`.
- **Cluster Mesh**: `clustermesh.useAPIServer: true`, NodePort-exposed
  (`32379`), TLS via a **shared** root issued once on hub and distributed to spokes
  through External Secrets (`PushSecret` on hub, `ExternalSecret` pull on spokes) —
  deliberately different from `internal-ca-issuer`, which is an independent per-cluster
  root. Services are made cross-cluster-visible with
  `service.cilium.io/global/shared: "true"` annotations (see
  `platform/charts/otel/templates/global-service.yaml` and
  `platform/monitoring-configs/mesh/hub-prometheus-mesh-service.yaml` for the pattern).
- **TLS**: cert-manager with `enableGatewayAPI: true` (gateway-shim watches Gateways
  instead of Ingress). Two independent PKI roots exist:
  1. `internal-ca-issuer` — per-cluster self-signed, used for Gateway listener certs
     and the pod-identity-webhook's own serving cert.
  2. `clustermesh-ca-issuer` — single shared root, used only for Cluster Mesh mTLS.

---

## 5. Identity — IRSA via a self-hosted pod-identity-webhook

Since this is self-hosted EC2 (not EKS), there's no built-in EKS pod-identity webhook.
`platform/values/base/pod-identity-webhook.yaml` deploys the unofficial
`amazon-eks-pod-identity-webhook` chart to fill that gap: it mutates any pod whose
ServiceAccount carries an `eks.amazonaws.com/role-arn` annotation, injecting
`AWS_ROLE_ARN` / `AWS_WEB_IDENTITY_TOKEN_FILE` and the projected SA token volume.

Key points:
- `mutatingWebhook.failurePolicy: Fail`, scoped narrowly via
  `objectSelector.matchLabels: {irsa.internal/inject: "true"}` so it only ever blocks
  admission for pods that explicitly opt in (every other pod in the cluster is
  unaffected) — see that values file's header comment for the full reasoning.
- Controllers wired to IRSA this way today: `ebs-csi` (controller), `external-secrets`,
  Tempo, Loki. Each sets both the opt-in `podLabels`/`serviceAccount` label and the
  `eks.amazonaws.com/role-arn` annotation in its tier values file.
- `cilium-operator` and `aws-cloud-controller-manager` use IRSA too, but inject the
  projected token **directly** (`extraVolumes`/`extraEnv`) rather than through the
  webhook — no dependency on wave 40.
- **Karpenter does not use IRSA** — its controller pod authenticates via the underlying
  EC2 instance's instance-profile role instead (see
  `platform/values/base/karpenter.yaml`'s header comment). This is a deliberate,
  documented exception, not an oversight.
- Any Application whose controller depends on IRSA-via-webhook (`aws-ebs-csi-driver`,
  `external-secrets`, hub's `tempo`/`loki`) carries a third Helm source pointing at
  `platform/webhook-guards/`, which adds a PreSync hook Job that blocks the real sync
  until `pod-identity-webhook` is confirmed `Running` — sync-wave ordering alone was
  found to race against this on a from-scratch bootstrap.

---

## 6. Observability Stack

| Signal | Path |
|---|---|
| Metrics | App/infra → ServiceMonitor/PodMonitor → spoke Prometheus (Agent) → `remote_write` → hub Prometheus → Grafana |
| Traces | App (OTel Python auto-instr.) → spoke OTel DaemonSet → (loadbalanced by traceID) → hub OTel Aggregator → tail-sampling → Tempo (S3-backed) |
| Logs | Container stdout (filelog) + SDK logs → spoke DaemonSet → hub Aggregator → Loki (S3-backed) |

Key design points:
- **Tail sampling** happens only on hub's aggregator, after all spans of a trace are
  routed (by `traceID`) to the same aggregator replica — required for correct sampling
  decisions on errors/slow-request policies.
- **Trace/log correlation**: the DaemonSet's `filelog` receiver parses the CRI
  containerd log header, extracts JSON body, promotes `trace_id`/`span_id` to resource
  attributes, so Grafana Explore can jump log→trace and vice versa (`derivedFields` in
  `loki-datasource.yaml`, `tracesToLogsV2` in `tempo-datasource.yaml`).
- **PII/secret redaction**: `attributes/redact` (drops `Authorization` header, hashes
  `db.statement`) and `transform/redact` (regex-scrubs `password|token|secret|key=`
  query params) run before export.
- **Dashboards** are plain `ConfigMap`s labeled `grafana_dashboard: "1"`, auto-imported
  by kube-prometheus-stack's Grafana sidecar. Datasource ConfigMaps
  (Loki/Tempo) are labeled `grafana_datasource: "1"` the same way.
- **Multi-cluster disambiguation**: once there's more than one spoke, `global.clusterName`
  (templated per-spoke as `{{name}}` in the otel-collectors ApplicationSet) is merged
  into both SDK-emitted span/log resource attributes and the DaemonSet's own
  `k8sattributes`/`resource` processor, so traces/logs/metrics landing in hub's single
  backend can still be told apart by source cluster.
- **KEDA** scales `fastapi-app` on two Prometheus-query triggers (RPS, P95 latency),
  querying **hub's** Prometheus (spoke's is Agent-mode and has no query API) — see the
  `clamp_min(...,1)` guard in `scaledobject.yaml` to avoid a divide-by-zero → `+Inf`
  blowing up the HPA if replicas ever drop to 0.
- **Monitoring-configs ownership**: `platform/monitoring-configs/` is split into one
  subdirectory per owning ArgoCD Application/ApplicationSet (`cilium/`, `mesh/`) —
  see its own `README.md`. Never add a manifest to an existing subdirectory unless it
  truly belongs to that same owner, and never share a directory between two owners via
  `directory.include`/`exclude` — that caused a real Service-ownership collision
  between `kube-prometheus-stack` and `cilium-servicemonitors` on hub.

---

## 7. Application Workloads

### `services/fastapi-app`
Deployment + Service + ServiceAccount + HTTPRoute + ScaledObject (KEDA) +
ServiceMonitor + Secret (DB creds). OTel auto-instrumentation is entirely
annotation-driven (`instrumentation.opentelemetry.io/inject-python`) — no SDK
wiring in the Deployment itself; the OTel Operator webhook injects everything at
admission time from the `Instrumentation` CR.

### `services/postgresql`
CloudNativePG `Cluster` (1 primary + 1 replica) + two `Pooler`s (PgBouncer, transaction
mode): `pg-pooler-rw` → primary only, `pg-pooler-ro` → load-balanced across replicas.
`enableSuperuserAccess: true`; app-user secret has `helm.sh/resource-policy: keep` so
Helm never deletes it on uninstall.

### `platform/karpenter/spoke`
Local chart templating a Karpenter `NodePool` + `EC2NodeClass` per spoke, driven by the
ApplicationSet's `{{name}}` cluster-generator variable (same pattern as cilium/otel).
Nodes bootstrap via a userData script that polls SSM for join credentials and joins via
`kubeadm` — this is a self-hosted, non-EKS node-join flow, not Karpenter's usual
EKS-managed path. Controller runs under the instance-profile role, not IRSA (see
Section 5).

---

## 8. Known Gaps / Things To Fix Before Prod

Cross-checked against `LIMITATIONS.md` and inline comments — some items previously
listed here are now resolved; treat this as the current backlog, not historical record.

1. **IAM is now mostly IRSA-based**, not instance-profile (`pod-identity-webhook` +
   direct-injection for cilium-operator/aws-ccm — see Section 5) — largely resolved.
   Remaining gap: **Karpenter still runs under the EC2 instance-profile role**, and
   that profile's policy is not scoped to least-privilege — verify/tighten before prod.
2. **Secrets committed in git as placeholders**: `services/postgresql/values.yaml`
   (`changeme`, base64) and `services/fastapi-app/values.yaml` (`changeme` DB password)
   are live source-of-truth for every spoke today — migrate to sealed-secrets or
   External Secrets before going past dev.
3. **NetworkPolicy / authorization** not implemented anywhere yet.
4. **No service mesh** — mTLS/traffic policy between in-cluster services relies solely
   on Cilium's L3/L4 identity model today, nothing L7-app-aware beyond the Gateway edge.
5. **OTel log pipeline doesn't parse DB logs' JSON** yet.
6. Several Service names (`kube-prometheus-stack-grafana`, `alertmanager-operated`,
   `hubble-ui`) are **VERIFY**-flagged assumptions about subchart-generated naming —
   confirm against `kubectl get svc` after first sync rather than trusting the comment.
7. **Cluster Mesh DR hazard**: if the `clustermesh-ca` Secret on hub is ever deleted
   (namespace recreation, hub rebuild), cert-manager silently mints a **new, different**
   root with no awareness that spokes still trust the old one pulled from AWS Secrets
   Manager — fleet-wide mTLS breaks silently. Back up `tls.crt`/`tls.key` (or confirm
   they match AWS Secrets Manager `clustermesh/ca`) before any hub rebuild.
8. Tempo/Loki S3 access now uses **IRSA** (`hub-dev-irsa-tempo`, `hub-dev-irsa-loki`) —
   previously instance-profile-only; confirm the role policies are scoped correctly in
   production rather than assuming the old instance-profile grant still applies.
9. Not yet tried on EKS (this whole platform assumes self-hosted EC2 nodes, including
   Karpenter's kubeadm-based node-join flow, which has no EKS equivalent as written).

---

## 9. Quick Reference — "Where do I find…"

| I want to change... | Edit this |
|---|---|
| Autoscaling thresholds for fastapi-app | `services/fastapi-app/values.yaml` → `keda.triggers` |
| DB size/replica count | `services/postgresql/values.yaml` → `cluster.instances` / `cluster.storage` |
| Add a new spoke | `argocd/clusters/<name>.yaml` (+ mesh-id/mesh-ip labels + IRSA role-arn annotations) |
| Add a Grafana dashboard | New ConfigMap under `platform/grafana-dashboards/`, label `grafana_dashboard: "1"` |
| Change trace sampling policy | `platform/charts/otel/values.yaml` → `collectorDeployment.tailSampling` |
| Change Gateway hostnames/TLS | `platform/gateway-api/{hub,spoke}-gateway.yaml` |
| Adjust hub vs spoke Prometheus behavior | `platform/values/{hub,spoke}/kube-prometheus-stack.yaml` |
| Change ordering/dependencies of a rollout | The `argocd.argoproj.io/sync-wave` annotation on the relevant Application/ApplicationSet |
| Add/rotate an IRSA role for a controller | The controller's tier values file (`serviceAccount.annotations["eks.amazonaws.com/role-arn"]`) + confirm `platform/values/base/pod-identity-webhook.yaml`'s `objectSelector` label is set on that controller's pod template |
| Adjust per-spoke node sizing/instance types | `platform/karpenter/spoke/values.yaml` (`instanceTypes`, `limits`) |