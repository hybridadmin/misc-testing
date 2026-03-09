# Jenkins CI/CD Pipeline — Multi-Environment Deploy

A production-hardened Jenkins pipeline that replaces the GitHub Actions workflow
(`ci.yml` + `promote.yml`) with a single parameterized Jenkinsfile. It builds,
pushes, and deploys a Docker image to any environment (`dev`, `staging`,
`production`) using a GitOps approach with Kustomize.

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                     Jenkins Pipeline                        │
│                                                             │
│  ┌──────────┐   ┌─────────────┐   ┌──────────┐            │
│  │  1. Test  │──▶│ 2. Build &  │──▶│ 3. Gate  │ (prod only)│
│  │  (pytest) │   │    Push     │   │ Approval │            │
│  └──────────┘   │  (GHCR)     │   └────┬─────┘            │
│                  └─────────────┘        │                   │
│                                         ▼                   │
│                              ┌───────────────────┐          │
│                              │ 4. Update GitOps  │          │
│                              │   Repo (kustomize │          │
│                              │   edit set image) │          │
│                              └─────────┬─────────┘          │
└────────────────────────────────────────┼────────────────────┘
                                         │ git push
                                         ▼
                               ┌──────────────────┐
                               │   Argo CD picks   │
                               │   up the change   │
                               │   and syncs K8s   │
                               └──────────────────┘
```

## Parameters

| Parameter     | Type   | Description                                                     |
|---------------|--------|-----------------------------------------------------------------|
| `ENVIRONMENT` | Choice | `dev`, `staging`, or `production`                               |
| `IMAGE_TAG`   | String | Tag to build & deploy (e.g. `v1.2.3`). Blank = auto from SHA.  |

## Prerequisites

### Jenkins Plugins

All plugins are pre-installed when using the Docker setup. The full list is in
[`docker/plugins.txt`](docker/plugins.txt). Highlights:

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

### Tools on the Jenkins Agent

Pre-installed in the Docker image:

- `docker` (CLI only — daemon is the DinD sidecar)
- `python3` + `pip` + `venv`
- `kustomize` (pinned v5.6.0)
- `git`, `curl`, `jq`

### Jenkins Credentials

Create these in **Jenkins > Manage Jenkins > Credentials**:

| ID                | Type              | Purpose                                         |
|-------------------|-------------------|-------------------------------------------------|
| `ghcr-credentials`| Username/Password | GitHub username + PAT with `write:packages` scope |
| `github-ssh-key`  | SSH Private Key   | SSH key with push access to the GitOps repo     |

## Setup

1. **Edit the `Jenkinsfile`** — replace the `TODO` placeholders:

   ```groovy
   IMAGE_NAME  = 'OWNER/pipeline'                            // your GitHub org/repo
   GITOPS_REPO = 'git@github.com:OWNER/pipeline-gitops.git'  // your GitOps repo
   ```

2. **Create a Jenkins Pipeline job** pointing at this repo:
   - New Item > Pipeline
   - Pipeline > Definition: **Pipeline script from SCM**
   - SCM: Git > Repository URL: your app repo
   - Script Path: `Jenkinsfile`

3. **Add credentials** as described above.

4. **Run the pipeline** — use "Build with Parameters" to pick an environment and tag.

## Production Deploys

When `ENVIRONMENT = production`, an **approval gate** pauses the pipeline before
the deploy stage. Only users in the `admin` or `release-managers` groups can approve.
This mirrors the GitHub environment protection rules from the original workflow.

## Mapping from the Original GitHub Workflows

| GitHub Actions                    | Jenkins Equivalent                                    |
|-----------------------------------|-------------------------------------------------------|
| `ci.yml` > test job               | `Test` stage (pytest in virtualenv)                   |
| `ci.yml` > build-and-push job     | `Build & Push` stage (docker build + push)            |
| `ci.yml` > update-manifests       | `Deploy` stage (kustomize edit + git push)            |
| `promote.yml` (workflow_dispatch) | Same pipeline with `ENVIRONMENT=production` + approval gate |
| `github.ref` branch mapping       | Explicit `ENVIRONMENT` parameter                      |
| GitHub environment approval        | `input` step with submitter restriction               |

---

## Local Testing with Docker Compose

A fully self-contained, production-hardened Jenkins server lives in the `docker/`
subdirectory. Everything is automated — dark theme, plugins, security, the
pipeline job — via Configuration as Code.

### Quick Start

```bash
cd docker/

# (Optional) customize settings
cp .env.example .env
vi .env

# Build and start
docker compose up -d --build

# Watch logs until Jenkins is ready
docker compose logs -f jenkins
```

Then open **http://localhost:8080** and log in:

| Field    | Value   |
|----------|---------|
| Username | `admin` |
| Password | `admin` |

> Change the password immediately in a real environment. Set
> `JENKINS_ADMIN_PASSWORD` in `.env` before first boot.

The `pipeline-deploy` job is already created. Click **Build with Parameters**.

### What's Inside `docker/`

```
docker/
├── docker-compose.yml   # Jenkins controller + Docker-in-Docker sidecar
├── Dockerfile           # Custom Jenkins image (plugins, python, kustomize)
├── plugins.txt          # 30+ curated Jenkins plugins
├── casc.yaml            # JCasC — full server config, theme, security, seed job
├── .env                 # Environment variables (passwords, ports, resources)
└── .env.example         # Template — safe to commit
```

| Service          | Purpose                                                   |
|------------------|-----------------------------------------------------------|
| `jenkins`        | Controller with all tools (python3, kustomize, docker CLI)|
| `docker` (DinD)  | Docker daemon — Jenkins delegates `docker build/push` here|

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
| `TZ`                      | `UTC`              | Timezone                         |

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
- CSP headers set to prevent XSS

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

### Notes

- The Jenkinsfile is bind-mounted from `../Jenkinsfile` into the container, so
  edits are picked up immediately — just re-run the job.
- Jenkins data persists in the `jenkins_home` Docker volume across restarts.
- The DinD sidecar uses TLS certs shared via the `docker_certs` volume.
- To add more JCasC config, edit `casc.yaml` and restart:
  `docker compose restart jenkins`
