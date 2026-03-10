# Jenkins CI/CD Pipeline — Multi-Environment Deploy

A production-hardened Jenkins pipeline that builds, tests, and deploys a Docker
image to any environment (`dev`, `staging`, `production`) using tag-based
releases and Kustomize overlays.

## Architecture

The setup uses two repositories:

| Repository | Purpose |
|------------|---------|
| **Pipeline source** (`jenkins-infra-source`) | Contains the Jenkinsfile only — fetched by Jenkins via SCM |
| **Application repo** (`owner-project-service`) | Application code, Dockerfile, and k8s manifests — built and deployed from here |

```
┌──────────────────────────────────┐
│  jenkins-infra-source            │  Pipeline source (SCM)
│  └── pipelines/Jenkinsfile       │  Jenkins fetches this only
└──────────────┬───────────────────┘
               │ lightweight checkout (Jenkinsfile only)
               v
┌──────────────────────────────────┐
│  Jenkins Pipeline:               │
│                                  │
│  1. Validate  (IMAGE_TAG)        │
│  2. Checkout  app repo @ tag ────┼──> git clone --branch v1.2.3
│  3. Test      (in app-src/)      │         │
│  4. Build     (in app-src/)      │         v
│  5. Approval  (prod only)        │  ┌────────────────────────────┐
│  6. Deploy    (in app-src/)      │  │  owner-project-service     │
│     - kustomize edit set image   │  │  ├── app/                  │
│     - git commit                 │  │  ├── Dockerfile            │
│     - git tag + push ────────────┼──│  └── k8s/overlays/{env}/   │
│                                  │  └────────────────────────────┘
└──────────────────────────────────┘
          deploy tag pushed:
     deploy-staging-v1.2.3
```

### How a deploy works

1. A developer pushes a git tag (e.g. `v1.2.3`) to the application repo
2. The Jenkins job is triggered — either automatically via webhook or manually via **Build with Parameters**
3. Jenkins fetches the Jenkinsfile from the pipeline source repo (lightweight SCM checkout)
4. The pipeline clones the application repo at the specified tag
5. Tests run, the Docker image is built and pushed to GHCR as `ghcr.io/<IMAGE_NAME>:<tag>`
6. Kustomize updates the image tag in `k8s/overlays/{environment}/`
7. A deploy tag (`deploy-{env}-{tag}`) is committed and pushed back to the application repo
8. Argo CD (or similar) picks up the deploy tag and syncs the cluster

## Job Structure

The pipeline job is organized under a Jenkins folder:

```
Jenkins
└── owner-project-service/          <-- folder
    └── pipeline-deploy             <-- pipeline job
```

The Jenkinsfile is fetched from the pipeline source repo via **Pipeline script
from SCM**. The application repo, environment, and tag are all configurable
from the Jenkins UI.

## Parameters

| Parameter     | Type   | Description                                                          |
|---------------|--------|----------------------------------------------------------------------|
| `APP_REPO`    | String | SSH URL of the application repo to build and deploy                  |
| `IMAGE_NAME`  | String | Container image name in the registry (e.g. `org/repo`). Pushed to `ghcr.io/<IMAGE_NAME>:<tag>`. |
| `IMAGE_TAG`   | String | Git tag to check out and deploy (e.g. `v1.2.3`) — **required**      |
| `ENVIRONMENT` | Choice | `dev`, `staging`, or `production`                                    |

## Prerequisites

### Jenkins Plugins

All plugins are pre-installed when using the Docker setup. The full list is in
[`plugins.txt`](plugins.txt). Highlights:

| Category            | Plugins                                              |
|---------------------|------------------------------------------------------|
| Pipeline            | workflow-aggregator, pipeline-graph-view, pipeline-utility-steps |
| Git & GitHub        | git, github, github-branch-source                    |
| Credentials         | credentials-binding, ssh-agent, hashicorp-vault-plugin |
| Docker              | docker-workflow, docker-commons                      |
| Theme               | dark-theme, theme-manager                            |
| UI                  | blueocean, timestamper, ansicolor                    |
| Security            | matrix-auth, role-strategy, authorize-project, script-security |
| Audit               | audit-trail                                          |
| Build Management    | ws-cleanup, build-timeout, throttle-concurrents, rebuild |
| Notifications       | mailer, email-ext, slack                             |
| Observability       | prometheus, cloudbees-disk-usage-simple               |
| Config as Code      | configuration-as-code, job-dsl                       |
| Webhooks            | generic-webhook-trigger                              |

### Tools on the Jenkins Agent

Pre-installed in the Docker image:

- `docker` (CLI only — daemon is the DinD sidecar)
- `python3` + `pip` + `venv`
- `kustomize` (pinned v5.6.0)
- `git`, `curl`, `jq`

### Jenkins Credentials

All credentials are provisioned automatically via JCasC from the `secrets/`
directory on boot. No manual credential setup is required.

| ID                | Type              | Purpose                                              | Provisioning     |
|-------------------|-------------------|------------------------------------------------------|------------------|
| `github-ssh-key`  | SSH Private Key   | Clones both repos and pushes deploy tags to app repo | Automatic (JCasC) |
| `ghcr-credentials`| Username/Password | GitHub username + PAT with `write:packages` scope    | Automatic (JCasC) |
| `webhook-token`   | Secret text       | Shared secret for GitHub webhook authentication      | Automatic (JCasC) |

See [Secrets Setup](#2-secrets-setup) for how to populate the secret files.

## Setup

### 1. Clone and configure

```bash
cp .env.example .env
vi .env                    # set JENKINS_ADMIN_PASSWORD at minimum
```

### 2. Secrets Setup

All credentials are loaded from files in the `secrets/` directory. Each file
becomes a resolvable `${FILENAME}` variable in `casc.yaml`.

#### SSH Key (machine user)

The pipeline uses a single SSH key to access both private repositories:

- **Pipeline source repo** (`jenkins-infra-source`) — read access (SCM checkout)
- **Application repo** (`owner-project-service`) — write access (clone + push deploy tags)

Since GitHub deploy keys are scoped to a single repo, the recommended approach
is to use a **machine user** (a GitHub service account) whose SSH key grants
access to both repos.

**Create the machine user:**

1. Create a dedicated GitHub account (e.g. `yourorg-ci`) to act as a service account
2. Generate an SSH key for it:
   ```bash
   ssh-keygen -t ed25519 -C "yourorg-ci" -f secrets/GITHUB_SSH_PRIVATE_KEY -N ""
   ```
3. Add the **public key** to the machine user's GitHub account:
   - Log in as the machine user
   - Go to **Settings > SSH and GPG keys > New SSH key**
   - Paste the contents of `secrets/GITHUB_SSH_PRIVATE_KEY.pub`

**Grant the machine user access to both repos:**

| Repository              | Access level | Why                                       |
|-------------------------|-------------|-------------------------------------------|
| `jenkins-infra-source`  | Read        | Fetch the Jenkinsfile via SCM             |
| `owner-project-service` | Write       | Clone at tag + push deploy tags back      |

Add the machine user as a collaborator on each repo with the appropriate
permission level.

#### GHCR Credentials

Create a GitHub Personal Access Token (PAT) with the `write:packages` scope:

```bash
echo "your-github-username" > secrets/GHCR_USERNAME
echo "ghp_your_personal_access_token" > secrets/GHCR_TOKEN
```

#### Webhook Token

Generate a random shared secret for webhook authentication:

```bash
openssl rand -hex 20 > secrets/WEBHOOK_TOKEN
```

You'll use this same token value when configuring the GitHub webhook (see
[Webhook Setup](#6-webhook-setup)).

#### How secrets work under the hood

- `docker-compose.yml` mounts `./secrets/` into the container at `/run/jenkins-secrets/` (read-only)
- The `SECRETS` environment variable tells JCasC to look in `/run/jenkins-secrets/` for file-based secrets
- JCasC resolves variables like `${GITHUB_SSH_PRIVATE_KEY}` by reading the corresponding file
- All credentials are registered globally and available to the pipeline

> **Important:** Never commit secrets to git. The `.gitignore` file
> excludes `secrets/*` (except the README) and `.env`.

### 3. Build and start

```bash
docker compose up -d --build

# Watch logs until Jenkins is ready
docker compose logs -f jenkins
```

### 4. Log in and verify

Open **http://localhost:8080** and log in:

| Field    | Value                                           |
|----------|-------------------------------------------------|
| Username | `admin` (or your `JENKINS_ADMIN_ID`)            |
| Password | `admin` (or your `JENKINS_ADMIN_PASSWORD`)      |

> Change the default password immediately. Set `JENKINS_ADMIN_PASSWORD` in
> `.env` before first boot.

The `owner-project-service/pipeline-deploy` job is already created with:

- **SCM** pointing at `jenkins-infra-source` to fetch the Jenkinsfile
- **Credentials** set to `github-ssh-key`
- **Parameters** for `APP_REPO`, `IMAGE_NAME`, `IMAGE_TAG`, and `ENVIRONMENT`

To verify or change the SCM config:

1. Navigate to **owner-project-service > pipeline-deploy > Configure**
2. Scroll to **Pipeline > SCM**
3. Verify the **Repository URL** is `git@github.com:hybridadmin/jenkins-infra-source.git`
4. Verify **Credentials** is set to `github-ssh-key`
5. Verify **Branch** is `*/main` and **Script Path** is `pipelines/Jenkinsfile`

### 5. Run the pipeline

1. Push a tag to the application repo:
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
2. **Option A — Manual:** In Jenkins, click **Build with Parameters**, set
   `IMAGE_TAG` to `v1.0.0`, select the target `ENVIRONMENT`, and click **Build**
3. **Option B — Automatic:** If the webhook is configured (see below), the
   pipeline triggers automatically when the tag is pushed. The default
   environment is `dev` for webhook-triggered builds.

### 6. Webhook Setup (optional)

The pipeline includes a **Generic Webhook Trigger** that can automatically start
a build when a tag is pushed to the application repo.

1. Read the webhook token you generated earlier:
   ```bash
   cat secrets/WEBHOOK_TOKEN
   ```
2. In the application repo on GitHub, go to **Settings > Webhooks > Add webhook**
3. Configure the webhook:

   | Field         | Value                                                                 |
   |---------------|-----------------------------------------------------------------------|
   | Payload URL   | `https://<your-jenkins-url>/generic-webhook-trigger/invoke?token=<WEBHOOK_TOKEN>` |
   | Content type  | `application/json`                                                    |
   | Secret        | *(leave empty — authentication is via the URL token)*                 |
   | Events        | **Just the push event**                                               |

4. Click **Add webhook**

The trigger only fires for tag pushes (not branch pushes). When a tag like
`v1.2.3` is pushed, the pipeline extracts the tag name from the webhook payload
and uses it as `IMAGE_TAG`. The default environment for webhook-triggered builds
is `dev`.

## Production Deploys

When `ENVIRONMENT = production`, an **approval gate** pauses the pipeline before
the deploy stage. Only users in the `admin` or `release-managers` groups can
approve. This mirrors the GitHub environment protection rules from the original
workflow.

## Deploy Tags

After a successful deploy, the pipeline pushes an annotated tag to the
application repo in the format:

```
deploy-{environment}-{image-tag}
```

For example: `deploy-staging-v1.2.3`, `deploy-production-v1.0.0`

These tags are immutable references that record exactly which version was
deployed to which environment. Argo CD can be configured to sync from tags
matching a pattern (e.g. `deploy-production-*`).

## Mapping from the Original GitHub Workflows

| GitHub Actions                    | Jenkins Equivalent                                    |
|-----------------------------------|-------------------------------------------------------|
| `ci.yml` > test job               | `Test` stage (pytest in virtualenv)                   |
| `ci.yml` > build-and-push job     | `Build & Push` stage (docker build + push)            |
| `ci.yml` > update-manifests       | `Deploy` stage (kustomize edit + deploy tag push)     |
| `promote.yml` (workflow_dispatch) | Same pipeline with `ENVIRONMENT=production` + approval gate |
| `github.ref` branch mapping       | Explicit `IMAGE_TAG` parameter (git tag)              |
| GitHub environment approval        | `input` step with submitter restriction               |

---

## Docker Setup Reference

### Directory Structure

```
docker/
├── README.md                # This file
├── .env                     # Environment variables — never committed
├── .env.example             # Template — safe to commit
├── .gitignore               # Excludes secrets/ and .env
├── Dockerfile               # Custom Jenkins image (plugins, python, kustomize)
├── casc.yaml                # JCasC — server config, credentials, theme, seed job
├── docker-compose.yml       # Jenkins controller + Docker-in-Docker sidecar
├── plugins.txt              # 30+ curated Jenkins plugins
└── secrets/                 # JCasC file-based secrets (gitignored)
    ├── README               # Setup instructions
    ├── GITHUB_SSH_PRIVATE_KEY   # SSH private key for machine user
    ├── GHCR_USERNAME            # GitHub username for GHCR
    ├── GHCR_TOKEN               # GitHub PAT with write:packages
    └── WEBHOOK_TOKEN            # Shared secret for webhook auth
```

> The Jenkinsfile lives in the separate pipeline source repo
> (`jenkins-infra-source/pipelines/Jenkinsfile`), not in this directory.

### Services

| Service          | Image                              | Purpose                                                    |
|------------------|------------------------------------|------------------------------------------------------------|
| `jenkins`        | Custom (see `Dockerfile`)          | Controller with all tools (python3, kustomize, docker CLI) |
| `docker` (DinD)  | `docker:27-dind`                   | Docker daemon — Jenkins delegates `docker build/push` here |

### Configuration via `.env`

All tunables are externalized so you never edit `docker-compose.yml` or `casc.yaml`:

| Variable                  | Default            | Description                      |
|---------------------------|--------------------|----------------------------------|
| `JENKINS_ADMIN_ID`        | `admin`            | Admin username                   |
| `JENKINS_ADMIN_PASSWORD`  | `admin`            | Admin password                   |
| `JENKINS_ADMIN_EMAIL`     | `jenkins-admin@example.com` | Admin email             |
| `JENKINS_URL`             | `http://localhost:8080/` | External URL (for reverse proxy) |
| `JENKINS_HTTP_PORT`       | `8080`             | Host port for web UI             |
| `JENKINS_AGENT_PORT`      | `50000`            | Host port for JNLP agents       |
| `JENKINS_HEAP_MIN`        | `512m`             | JVM min heap                     |
| `JENKINS_HEAP_MAX`        | `1024m`            | JVM max heap                     |
| `JENKINS_CPU_LIMIT`       | `2.0`              | CPU limit for Jenkins container  |
| `JENKINS_MEM_LIMIT`       | `2G`               | Memory limit for Jenkins container|
| `DIND_CPU_LIMIT`          | `2.0`              | CPU limit for DinD container     |
| `DIND_MEM_LIMIT`          | `2G`               | Memory limit for DinD container  |
| `JENKINS_SECRETS_DIR`     | `./secrets`        | Path to JCasC secrets directory  |
| `TZ`                      | `UTC`              | Timezone                         |

### Volumes

| Volume                   | Purpose                                |
|--------------------------|----------------------------------------|
| `jenkins_home`           | Jenkins data (jobs, builds, config)    |
| `jenkins_docker_certs`   | TLS certs shared between Jenkins and DinD |
| `jenkins_docker_data`    | Docker daemon storage (images, layers) |

### Production Hardening Checklist

The Docker setup applies these best practices out of the box:

**Security**
- Setup wizard disabled — all config via JCasC (reproducible, auditable)
- Matrix-based authorization (granular permissions, not "logged-in users can do anything")
- CSRF protection enabled with crumb issuer
- Only modern agent protocols allowed (JNLP4-connect, Ping)
- Script security and sandbox enabled for all pipeline scripts
- Legacy API token creation disabled
- Signup disabled
- Secrets managed via file-based JCasC secrets (never in YAML or env files)
- GitHub SSH host keys pre-seeded at build time (no TOFU prompts)
- Webhook endpoint protected by shared secret token

**Theme & UX**
- Dark theme (auto-switches based on OS preference via `darkSystem`)
- Blue Ocean installed for a modern pipeline visualization UI
- ANSI color and timestamps on all pipeline output
- Locale locked to `en_US` for consistent UI regardless of browser

**Observability**
- Prometheus metrics endpoint at `/prometheus`
- Audit trail logging all configuration changes
- Disk usage monitoring

**Reliability**
- Healthchecks on both containers (auto-restart on failure)
- Container resource limits (CPU + memory)
- Log rotation (10MB x 5 files per container)
- Build log rotation (keep last 20 builds, 5 artifacts)
- Pipeline durability set to `PERFORMANCE_OPTIMIZED`
- Named volumes for data persistence
- G1GC with string deduplication for JVM efficiency
- `casc.yaml` volume-mounted for hot-reload without image rebuild

**Docker Image**
- Pinned Jenkins LTS version (`2.504.1-lts-jdk17`)
- Pinned kustomize version (`v5.6.0`)
- Docker CLI installed from official apt repo (not `docker.io` package)
- Non-root user (`jenkins`) at runtime
- Container healthcheck built into the image

### Blue Ocean UI

For a modern pipeline visualization, navigate to:

```
http://localhost:8080/blue
```

### Prometheus Metrics

Scrape Jenkins metrics at:

```
http://localhost:8080/prometheus/
```

### Tearing It Down

```bash
# Stop and remove containers (keeps volumes for next time)
docker compose down

# Full cleanup including all data
docker compose down -v
```

### Troubleshooting

**Jenkins fails to start with credential errors:**
Ensure all required files exist in the `secrets/` directory:
`GITHUB_SSH_PRIVATE_KEY`, `GHCR_USERNAME`, `GHCR_TOKEN`, `WEBHOOK_TOKEN`.
JCasC will log a warning if it cannot resolve a `${VARIABLE}`, but Jenkins will
still start — the corresponding credential will just be empty.

**SCM checkout fails with "Host key verification failed":**
The Docker image pre-seeds GitHub's SSH host keys at build time. If you see this
error, rebuild the image to refresh the keys:
```bash
docker compose up -d --build
```

**SCM checkout fails with "Permission denied (publickey)":**
1. Verify the machine user's public key is added to their GitHub account
2. Verify the machine user has access to both `jenkins-infra-source` (read) and `owner-project-service` (write)
3. Check the credential ID in the job config matches `github-ssh-key`
4. Ensure repo URLs use the SSH format (`git@github.com:...`), not HTTPS

**Pipeline cannot push deploy tags to the app repo:**
The machine user needs **write access** on the application repo. Verify the
collaborator permission level in GitHub.

**IMAGE_TAG error — "specify the git tag to build":**
The `IMAGE_TAG` parameter is required and must match an existing tag in the
application repo. Push a tag first:
```bash
git tag v1.0.0 && git push origin v1.0.0
```

**Changes to `casc.yaml` are not picked up:**
The `casc.yaml` is volume-mounted into the container (not baked into the image).
After editing, you can either restart Jenkins or trigger a hot-reload:
```bash
# Option 1: Restart the container
docker compose restart jenkins

# Option 2: Hot-reload via the JCasC endpoint (no restart needed)
curl -X POST "http://localhost:8080/configuration-as-code/reload" \
  -u admin:your-password
```
