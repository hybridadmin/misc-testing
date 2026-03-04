# Geocoding Helm Chart

Umbrella (wrapper) Helm chart that deploys [Nominatim](https://nominatim.org/) using the upstream [robjuz/nominatim](https://artifacthub.io/packages/helm/robjuz/nominatim) chart (v5.2.0) as a subchart dependency, with custom **NetworkPolicy** and **Ingress** templates managed locally.

Designed for deployment via **ArgoCD** as a single application per environment.

## Chart structure

```
.
├── Chart.yaml                 # Umbrella chart definition (name: geocoding)
├── Chart.lock                 # Dependency lock file
├── charts/
│   └── nominatim-5.2.0.tgz   # Downloaded subchart
├── templates/
│   ├── _helpers.tpl           # Template helpers (chart.nominatim.fullname, chart.namespace)
│   ├── ingress.yaml           # Custom Ingress (AWS ALB)
│   └── networkpolicy.yml      # Custom NetworkPolicy
├── values.yaml                # Default values
├── values-prodct.yaml         # Production Cape Town (af-south-1)
├── values-prodire.yaml        # Production Ireland (eu-west-1)
├── values-systest.yaml        # System Test (eu-west-1)
├── argocd/
│   └── application.yaml       # Example ArgoCD Application manifest
└── .helmignore
```

## How values are organized

Values are split into two scopes:

| Scope | Keys | Purpose |
|-------|------|---------|
| **Wrapper chart** (top-level) | `project`, `env`, `cidr_range`, `networkpolicy`, `customIngress`, `network` | Drive the custom NetworkPolicy and Ingress templates |
| **Upstream subchart** | `nominatim.*` | Passed directly to the `robjuz/nominatim` subchart |

The upstream subchart's own ingress is **always disabled** (`nominatim.ingress.enabled: false`). The custom `customIngress` template replaces it, providing AWS ALB annotations and multi-host support.

## Environments

| File | Environment | Region | Ingress hostname(s) |
|------|-------------|--------|---------------------|
| `values-prodct.yaml` | Production Cape Town | `af-south-1` | `geocode-cpt.moya.app`, `geocode.moya.app` |
| `values-prodire.yaml` | Production Ireland | `eu-west-1` | `geocode-ire.moya.app` |
| `values-systest.yaml` | System Test | `eu-west-1` | `geocode.atlas.systest.moya.app` |

All environments use:
- An **external PostgreSQL** database (internal PostgreSQL disabled)
- A **CronJob** for replication updates (south-africa region data)
- Port **8080** for the service

## Prerequisites

- Helm 3.x
- Access to the `robjuz` Helm repository (fetched automatically via `helm dependency update`)

## Usage

### Build / update dependencies

```bash
helm dependency update
```

### Validate templates

Render templates locally for a specific environment without installing:

```bash
# Production Cape Town
helm template geocoding-prodct . -f values.yaml -f values-prodct.yaml --namespace geocoding-prodct

# Production Ireland
helm template geocoding-prodire . -f values.yaml -f values-prodire.yaml --namespace geocoding-prodire

# System Test
helm template geocoding-systest . -f values.yaml -f values-systest.yaml --namespace geocoding-systest
```

### Install manually (without ArgoCD)

```bash
helm install geocoding-prodct . \
  -f values.yaml \
  -f values-prodct.yaml \
  --namespace geocoding-prodct \
  --create-namespace
```

### Deploy via ArgoCD

An example ArgoCD `Application` manifest is provided in `argocd/application.yaml`. Update the `repoURL` and `path` fields to match your repository, then apply:

```bash
kubectl apply -f argocd/application.yaml
```

ArgoCD will layer the environment-specific values file on top of the defaults using the `valueFiles` list in the Helm source configuration.

## Custom templates

### Ingress (`templates/ingress.yaml`)

Controlled by the `customIngress` values key. Supports:
- AWS ALB annotations (certificate ARN, target type, health checks, etc.)
- Multiple host rules via `customIngress.extraHosts`
- Optional TLS with auto-generated secret names

Enabled per environment by setting `customIngress.enabled: true`.

### NetworkPolicy (`templates/networkpolicy.yml`)

Controlled by the `networkpolicy` values key. Creates a policy that:
- Allows ingress from three `/20` public subnets derived from `cidr_range`
- Allows ingress from the same namespace
- Allows ingress on the service port (`nominatim.service.ports.http`)
- Optionally allows Prometheus scraping (`network.prometheus` port list)
- Allows egress to ports 443, 80, 53 (DNS), and 5432 (PostgreSQL)

Enabled per environment by setting `networkpolicy.enabled: true`.

## Template helpers

Defined in `templates/_helpers.tpl`:

| Helper | Purpose |
|--------|---------|
| `chart.nominatim.fullname` | Computes the fullname for subchart resources, matching the upstream naming logic. Used by the Ingress to point its backend at the correct Service. |
| `chart.namespace` | Returns the release namespace (or `namespaceOverride` if set). |

## Key differences from the old v3.x chart

This chart is based on the upstream nominatim chart **v5.2.0**, which has significant changes from v3.x:

| Old (v3.x) | New (v5.2.0) |
|-------------|--------------|
| `service.port` | `nominatim.service.ports.http` |
| `nominatimInitialize.*` | `nominatim.initJob.*` |
| `nominatimReplications.*` | `nominatim.updates.*` (CronJob-based) |
| `nominatim.extraEnv` | `nominatim.extraEnvVars` |
| Replication threads as a dedicated field | Inline in `nominatim.updates.args` |
| Bundled ingress template | Custom `customIngress` template (upstream ingress disabled) |

## Notes

- Do **not** set `nominatim.image.tag: ""` — this causes a render error. Omit the `tag` key entirely to use the subchart's default (`appVersion: 5.1.0`).
- The subchart uses [bitnami/common](https://github.com/bitnami/charts/tree/main/bitnami/common) v2.21.0 for its templates.
- LSP warnings on `.yaml` template files containing Go template syntax (`{{ }}`) are expected and harmless.
