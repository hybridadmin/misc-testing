# Pipeline - GitHub Actions + Argo CD CI/CD

A complete GitOps CI/CD pipeline for a Python FastAPI application, using GitHub Actions for CI and Argo CD for continuous delivery to Kubernetes.

## Architecture

```
Push to GitHub ──> GitHub Actions (CI) ──> GHCR (image) ──> Git commit (manifests) ──> Argo CD (CD) ──> K8s
```

### Deployment Flow

| Trigger | Branch | Environment | Argo CD Sync |
|---------|--------|-------------|--------------|
| `git push` | `develop` | dev | Automated |
| `git push` | `main` | staging | Automated |
| Manual workflow dispatch | `main` | production | Manual (approval required) |

## Project Structure

```
.
├── app/                          # Python application
│   ├── main.py                   # FastAPI app
│   ├── requirements.txt          # Production dependencies
│   ├── requirements-dev.txt      # Dev/test dependencies
│   └── tests/                    # Test suite
├── Dockerfile                    # Multi-stage container build
├── .github/workflows/
│   ├── ci.yml                    # CI pipeline (test → build → update manifests)
│   └── promote.yml               # Manual production promotion
├── k8s/                          # Kubernetes manifests (Kustomize)
│   ├── base/                     # Shared base resources
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   └── overlays/
│       ├── dev/                  # Dev overrides (1 replica, low resources)
│       ├── staging/              # Staging overrides (2 replicas)
│       └── production/           # Production overrides (3 replicas, high resources)
└── argocd/                       # Argo CD Application definitions
    ├── project.yaml              # AppProject
    ├── dev.yaml                  # Dev Application (auto-sync)
    ├── staging.yaml              # Staging Application (auto-sync)
    └── production.yaml           # Production Application (manual sync)
```

## Prerequisites

- A Kubernetes cluster with [Argo CD](https://argo-cd.readthedocs.io/en/stable/getting_started/) installed
- A GitHub repository (for source code + container registry)
- `kubectl` and `kustomize` CLI tools

## Setup

### 1. Replace Placeholders

Search and replace the following across all files:

| Placeholder | Replace With | Example |
|-------------|-------------|---------|
| `OWNER/pipeline` | Your GitHub `owner/repo` | `myorg/myapp` |
| `OWNER` | Your GitHub username or org | `myorg` |

### 2. Configure GitHub

1. **Enable GitHub Actions** — should be enabled by default
2. **Enable GHCR** — push at least one image, or enable packages in repo settings
3. **(Optional) Create a `production` environment** in repo Settings > Environments, and add a required reviewer for manual approval

### 3. Register the Repo in Argo CD

```bash
argocd repo add https://github.com/OWNER/pipeline.git \
  --username <github-username> \
  --password <github-pat-or-deploy-key>
```

### 4. Create Namespaces (or let Argo CD do it)

```bash
kubectl create namespace pipeline-dev
kubectl create namespace pipeline-staging
kubectl create namespace pipeline-production
```

### 5. Apply Argo CD Applications

```bash
kubectl apply -f argocd/
```

### 6. Push Code and Watch It Deploy

```bash
git push origin develop   # → deploys to dev
git push origin main      # → deploys to staging
```

To promote to production:
1. Go to **Actions > Promote to Production** in GitHub
2. Enter the image tag (e.g. `sha-abc1234`)
3. Click **Run workflow**
4. Approve the sync in Argo CD UI

## Local Development

```bash
# Install dependencies
pip install -r app/requirements-dev.txt

# Run the app
uvicorn app.main:app --reload

# Run tests
pytest app/tests/ -v
```

## GHCR Authentication for Kubernetes

If your GHCR images are private, create an image pull secret:

```bash
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<github-pat> \
  -n pipeline-dev

# Repeat for staging and production namespaces
```

Then add `imagePullSecrets` to the deployment (or patch via Kustomize).

## How the Pipeline Works

### CI: GitHub Actions (`.github/workflows/ci.yml`)

The CI pipeline is triggered automatically via GitHub's built-in webhook mechanism whenever code is pushed or a pull request is opened. No manual webhook configuration is needed — GitHub Actions handles this natively.

**On Pull Request (to `main`):**

1. Checks out the code
2. Sets up Python 3.12 with pip caching
3. Installs dev dependencies
4. Runs the test suite via `pytest`
5. Reports pass/fail status back to the PR

**On Push (to `main` or `develop`):**

1. **Test job** — same as above
2. **Build & Push job** (runs after tests pass):
   - Authenticates to GHCR using the built-in `GITHUB_TOKEN`
   - Generates image tags (git SHA short hash + branch name)
   - Builds a multi-stage Docker image
   - Pushes to `ghcr.io/<owner>/<repo>:<tag>`
3. **Update Manifests job** (runs after image is pushed):
   - Determines the target environment from the branch (`develop` -> dev, `main` -> staging)
   - Uses `kustomize edit set image` to update the image tag in the appropriate overlay
   - Commits and pushes the manifest change back to the repo

### CD: Argo CD

Argo CD runs inside the Kubernetes cluster and continuously watches this Git repository for changes to the `k8s/` directory.

1. When the CI pipeline commits an updated image tag to `k8s/overlays/<env>/kustomization.yaml`, Argo CD detects the diff
2. For **dev** and **staging**, Argo CD automatically syncs — it applies the updated manifests to the cluster, resulting in a rolling deployment
3. For **production**, Argo CD shows the diff in its UI/CLI but waits for a manual sync approval
4. Argo CD's `selfHeal` policy (enabled for dev/staging) ensures any manual cluster changes are reverted to match Git — Git is the single source of truth

### Production Promotion (`.github/workflows/promote.yml`)

Production deployments are intentionally manual:

1. A developer triggers the **Promote to Production** workflow from the GitHub Actions UI
2. They provide the exact image tag to deploy (e.g., `sha-abc1234` — taken from a successful staging deployment)
3. If a GitHub environment protection rule is configured, a reviewer must approve
4. The workflow updates `k8s/overlays/production/kustomization.yaml` with the specified tag
5. Argo CD detects the change and shows it as "OutOfSync" in the UI
6. An operator manually syncs in Argo CD to complete the production deployment

## Customization

### Adding environment variables

Add a ConfigMap to `k8s/base/` and reference it in the deployment:

```yaml
# k8s/base/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pipeline-app-config
data:
  LOG_LEVEL: "info"
```

Then add it to `k8s/base/kustomization.yaml` under `resources` and mount it in the deployment via `envFrom`.

### Adding an Ingress

Create an ingress in the appropriate overlay. For example, for staging:

```yaml
# k8s/overlays/staging/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pipeline-app
spec:
  rules:
    - host: staging.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: pipeline-app
                port:
                  number: 80
```

Then add it to the overlay's `kustomization.yaml` under `resources`.

### Scaling resources per environment

Resource limits and replica counts are already configured per overlay via JSON patches in each `kustomization.yaml`. Edit the `patches` section in the relevant overlay to adjust CPU, memory, or replica count.

### Adding secrets

Never commit plain secrets to Git. Use one of these approaches:

- **Sealed Secrets** — encrypt secrets client-side, commit the sealed version, controller decrypts in-cluster
- **External Secrets Operator** — syncs secrets from AWS Secrets Manager, Vault, GCP Secret Manager, etc.
- **Argo CD Vault Plugin** — injects secrets from Vault at sync time

## Troubleshooting

### CI pipeline fails at "Build and push image"

- Ensure the repo has **packages write** permission. Go to repo Settings > Actions > General > Workflow permissions and select "Read and write permissions".

### Argo CD shows "Unknown" or can't access the repo

- Verify the repo is registered: `argocd repo list`
- Re-add if needed: `argocd repo add <url> --username <user> --password <token>`
- For private repos, ensure the PAT has `repo` and `read:packages` scopes

### Argo CD shows "OutOfSync" but won't sync

- Check for sync errors: `argocd app get pipeline-app-<env>`
- Look at events: `kubectl describe application pipeline-app-<env> -n argocd`
- Common causes: namespace doesn't exist, RBAC issues, image pull failures

### Pods stuck in ImagePullBackOff

- The GHCR image is likely private. Create an image pull secret (see [GHCR Authentication](#ghcr-authentication-for-kubernetes) above)
- Verify the image exists: `docker pull ghcr.io/<owner>/<repo>:<tag>`

### Manifest update commit conflicts

If the CI "Update K8s Manifests" job fails with a git conflict, it usually means two pushes happened close together. Re-run the failed workflow, or push again to trigger a new run.
