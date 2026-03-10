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
│  │  1. Test  │──>│ 2. Build &  │──>│ 3. Gate  │ (prod only)│
│  │  (pytest) │   │    Push     │   │ Approval │            │
│  └──────────┘   │  (GHCR)     │   └────┬─────┘            │
│                  └─────────────┘        │                   │
│                                         v                   │
│                              ┌───────────────────┐          │
│                              │ 4. Update GitOps  │          │
│                              │   Repo (kustomize │          │
│                              │   edit set image) │          │
│                              └─────────┬─────────┘          │
└────────────────────────────────────────┼────────────────────┘
                                         │ git push
                                         v
                               ┌──────────────────┐
                               │   Argo CD picks   │
                               │   up the change   │
                               │   and syncs K8s   │
                               └──────────────────┘
```

## Job Structure

The pipeline job is organized under a Jenkins folder:

```
Jenkins
└── owner-project-service/          <-- folder
    └── pipeline-deploy             <-- pipeline job
```

The job uses **Pipeline script from SCM** — the Git repository URL, branch, and
Jenkinsfile path are all configurable from the Jenkins UI via
**Job > Configure > Pipeline**.

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

The following credentials are required. The SSH deploy key (`github-ssh-key`) is
provisioned automatically via JCasC from the `secrets/` directory (see
[SSH Deploy Key Setup](#ssh-deploy-key-setup) below). The GHCR credential must
be created manually in **Jenkins > Manage Jenkins > Credentials**.

| ID                | Type              | Purpose                                          | Provisioning |
|-------------------|-------------------|--------------------------------------------------|--------------|
| `github-ssh-key`  | SSH Private Key   | Pulls the source repo and pushes to the GitOps repo | Automatic (JCasC) |
| `ghcr-credentials`| Username/Password | GitHub username + PAT with `write:packages` scope  | Manual       |

## Setup

### 1. Clone and configure

```bash
cd docker/
cp .env.example .env
vi .env                    # set JENKINS_ADMIN_PASSWORD at minimum
```

### 2. SSH Deploy Key Setup

The pipeline needs an SSH key to pull from GitHub (SCM checkout) and push to the
GitOps repo. Jenkins provisions this credential automatically on boot using
JCasC file-based secrets.

**Generate the key:**

```bash
ssh-keygen -t ed25519 -C "jenkins-deploy" -f docker/secrets/GITHUB_SSH_PRIVATE_KEY -N ""
```

**Register the public key on GitHub:**

1. Copy the public key:
   ```bash
   cat docker/secrets/GITHUB_SSH_PRIVATE_KEY.pub
   ```
2. Go to your GitHub repo > **Settings > Deploy keys > Add deploy key**
3. Paste the public key and give it a descriptive title
4. For the source repo (SCM checkout), **read-only** access is sufficient
5. For the GitOps repo, enable **Allow write access** (the deploy stage pushes commits)

> If the source repo and GitOps repo are different, you need to add the public
> key to both repos, or use a machine user's SSH key with access to both.

**How it works under the hood:**

- `docker-compose.yml` mounts `./secrets/` into the container at `/run/jenkins-secrets/` (read-only)
- The `SECRETS` environment variable tells JCasC to look in `/run/jenkins-secrets/` for file-based secrets
- JCasC resolves `${GITHUB_SSH_PRIVATE_KEY}` in `casc.yaml` by reading the file `/run/jenkins-secrets/GITHUB_SSH_PRIVATE_KEY`
- The credential is registered globally with ID `github-ssh-key` and is available to all jobs

> **Important:** Never commit private keys to git. The `docker/.gitignore` file
> excludes `secrets/*` (except the README) and `.env`.

### 3. Edit the Jenkinsfile

Replace the `TODO` placeholders with your actual values:

```groovy
IMAGE_NAME  = 'OWNER/pipeline'                            // your GitHub org/repo
GITOPS_REPO = 'git@github.com:OWNER/pipeline-gitops.git'  // your GitOps repo
```

### 4. Build and start

```bash
cd docker/
docker compose up -d --build

# Watch logs until Jenkins is ready
docker compose logs -f jenkins
```

### 5. Log in and configure the repo

Open **http://localhost:8080** and log in:

| Field    | Value                                           |
|----------|-------------------------------------------------|
| Username | `admin` (or your `JENKINS_ADMIN_ID`)            |
| Password | `admin` (or your `JENKINS_ADMIN_PASSWORD`)      |

> Change the default password immediately. Set `JENKINS_ADMIN_PASSWORD` in `.env` before first boot.

The `owner-project-service/pipeline-deploy` job is already created. To set the
source repository:

1. Navigate to **owner-project-service > pipeline-deploy > Configure**
2. Scroll to **Pipeline > SCM**
3. Set the **Repository URL** (e.g. `git@github.com:your-org/your-repo.git`)
4. Verify **Credentials** is set to `github-ssh-key`
5. Set the **Branch** (default: `*/main`)
6. Set the **Script Path** (default: `Jenkinsfile`)
7. Click **Save**

### 6. Run the pipeline

Click **Build with Parameters**, select an environment and optional image tag,
then click **Build**.

## Production Deploys

When `ENVIRONMENT = production`, an **approval gate** pauses the pipeline before
the deploy stage. Only users in the `admin` or `release-managers` groups can
approve. This mirrors the GitHub environment protection rules from the original
workflow.

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

## Docker Setup Reference

### Directory Structure

```
jenkins/
├── Jenkinsfile              # Pipeline script (fetched from SCM at runtime)
├── README.md
└── docker/
    ├── .env                 # Environment variables — never committed
    ├── .env.example         # Template — safe to commit
    ├── .gitignore           # Excludes secrets/ and .env
    ├── Dockerfile           # Custom Jenkins image (plugins, python, kustomize)
    ├── casc.yaml            # JCasC — server config, credentials, theme, seed job
    ├── docker-compose.yml   # Jenkins controller + Docker-in-Docker sidecar
    ├── plugins.txt          # 30+ curated Jenkins plugins
    └── secrets/             # JCasC file-based secrets (gitignored)
        ├── README           # Setup instructions
        └── GITHUB_SSH_PRIVATE_KEY   # <-- you create this
```

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

### Troubleshooting

**Jenkins fails to start with credential errors:**
Ensure the `secrets/GITHUB_SSH_PRIVATE_KEY` file exists and contains a valid
PEM-format SSH private key. JCasC will log a warning if it cannot resolve the
`${GITHUB_SSH_PRIVATE_KEY}` variable, but Jenkins will still start — the
credential will just be empty.

**SCM checkout fails with "Permission denied (publickey)":**
1. Verify the deploy key's public key is added to the GitHub repo
2. Check the credential ID in the job config matches `github-ssh-key`
3. Ensure the repo URL uses the SSH format (`git@github.com:...`), not HTTPS

**Pipeline cannot push to the GitOps repo:**
The deploy key needs **write access** on the GitOps repo. Edit the deploy key
in GitHub and enable "Allow write access".

**Changes to `casc.yaml` are not picked up:**
The `casc.yaml` is baked into the Docker image at build time. After editing,
rebuild the image:
```bash
docker compose up -d --build
```
