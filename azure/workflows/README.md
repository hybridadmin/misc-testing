# Azure Pipelines - Ported GitHub Actions Workflows

This repository contains Azure Pipelines templates ported from the
[shared-workflows](https://github.com/moya-app/shared-workflows) GitHub Actions
reusable workflows.

## Repository Structure

```
workflows/
  shared/                              # Reusable pipeline templates (equivalent to workflow_call)
    build-push.yml                     # Docker multi-arch build, ECR push, manifest, webhook
    docker-build.yml                   # Docker test build (amd64+arm64), optional GHCR push
    frontend-build.yml                 # Frontend (Angular/SolidJS) build, test, artifact upload
    generic-no-buildtarget.yml         # Generic Docker test suite (no build target)
    ghcr-build-push.yml                # Multi-arch Docker build via QEMU, GHCR push
    helm-chart.yml                     # Helm chart lint (ct), kubeconform, unit tests
    java.yml                           # Java Docker-compose test suite, OpenAPI/Spectral
    packages.yml                       # GitHub Packages version cleanup
    python.yml                         # Python test suite (lint, test, coverage, OpenAPI)
    python-wheel.yml                   # Python wheel build (cibuildwheel + uv) and devpi upload
    webhook-only.yml                   # Deployment webhook with Slack notification
  angular-build-pipeline.yml           # Angular consumer for shared/frontend-build.yml
  build-push-pipeline.yml              # Consumer for shared/build-push.yml
  docker-build-pipeline.yml            # Consumer for shared/docker-build.yml
  frontend-build-pipeline.yml          # Generic consumer for shared/frontend-build.yml
  generic-no-buildtarget-pipeline.yml  # Consumer for shared/generic-no-buildtarget.yml
  ghcr-build-push-pipeline.yml         # Consumer for shared/ghcr-build-push.yml
  helm-chart-pipeline.yml              # Consumer for shared/helm-chart.yml
  java-pipeline.yml                    # Consumer for shared/java.yml
  packages-pipeline.yml                # Consumer for shared/packages.yml
  python-pipeline.yml                  # Consumer for shared/python.yml
  python-wheel-pipeline.yml            # Consumer for shared/python-wheel.yml
  solidjs-pipeline.yml                 # SolidJS consumer for shared/frontend-build.yml
  webhook-only-pipeline.yml            # Consumer for shared/webhook-only.yml
  README.md
```

### Convention

| Location | Purpose |
|---|---|
| `shared/<name>.yml` | Reusable template (maps to a GitHub Actions `workflow_call` workflow) |
| `<name>-pipeline.yml` | Example consumer pipeline showing how to call the template |

## Porting Status

| GitHub Actions Workflow | Azure Template | Status | Notes |
|---|---|---|---|
| `build-push.yml` | `shared/build-push.yml` | Ported | |
| `python.yml` | `shared/python.yml` | Ported | |
| `python-wheel.yml` | `shared/python-wheel.yml` | Ported | |
| `webhook-only.yml` | `shared/webhook-only.yml` | Ported | |
| `packages.yml` | `shared/packages.yml` | Ported | Uses `gh` CLI against GitHub Packages API |
| `helm-chart.yml` | `shared/helm-chart.yml` | Ported | |
| `ghcr-build-push.yml` | `shared/ghcr-build-push.yml` | Ported | |
| `docker-build.yml` | `shared/docker-build.yml` | Ported | |
| `java.yml` | `shared/java.yml` | Ported | |
| `generic-no-buildtarget.yml` | `shared/generic-no-buildtarget.yml` | Ported | |
| `angular-build.yml` | `shared/frontend-build.yml` | Ported | Consolidated with `solidjs.yml` (identical) |
| `solidjs.yml` | `shared/frontend-build.yml` | Ported | Consolidated with `angular-build.yml` (identical) |
| `opencode.yml` | — | N/A | Comment-triggered (`issue_comment`); no Azure Pipelines equivalent |

## Common Porting Patterns

The following patterns are used consistently across all ported templates. Follow
these when porting additional GitHub Actions workflows.

### GitHub Actions → Azure Pipelines Concept Map

| GitHub Actions | Azure Pipelines |
|---|---|
| `workflow_call` (reusable workflow) | Template with `parameters:` (consumed via `extends:`) |
| `inputs:` | `parameters:` |
| `secrets.*` | Variable groups linked to pipeline, or Azure Key Vault |
| `vars.*` | Variable groups (non-secret) |
| `needs:` (job dependency) | `dependsOn:` (stage dependency) |
| `runs-on: ubuntu-24.04` | `pool: { vmImage: 'ubuntu-24.04' }` |
| `runs-on: ubuntu-24.04-arm` | `pool: { name: '<self-hosted-arm-pool>' }` (no hosted ARM agents) |
| `strategy.matrix` with `fromJSON()` | Separate parallel stages (Azure can't do dynamic matrices from outputs) |
| Static `strategy.matrix` | Separate parallel stages (for pool flexibility per arch) |
| `${{ github.* }}` context | `$(Build.*)`, `$(System.*)` predefined variables |
| `>> $GITHUB_OUTPUT` | `##vso[task.setvariable variable=NAME;isOutput=true]VALUE` |
| `actions/checkout` | `checkout: self` (with `submodules`, `fetchDepth`, `persistCredentials`) |
| `docker/login-action` | `docker login` via bash |
| `docker/build-push-action` | `docker buildx build` via bash |
| `docker/setup-buildx-action` | `docker buildx create --use` via bash |
| `docker/setup-qemu-action` | `docker run --privileged multiarch/qemu-user-static` |
| `aws-actions/configure-aws-credentials` | `aws ecr get-login-password` via bash + env vars from variable group |
| `actions/upload-artifact` | `PublishPipelineArtifact@1` task |
| `actions/download-artifact` | `DownloadPipelineArtifact@2` task |
| `timheuer/base64-to-file` | `echo "$VAR" \| base64 -d > file` via bash |
| `slackapi/slack-github-action` | `curl` to Slack webhook via bash |
| `distributhor/workflow-webhook` | `curl` with HMAC-SHA256 signature via bash |
| `d3adb5/helm-unittest-action` | `helm plugin install helm-unittest` + `helm unittest` |
| `actions/cache` | `Cache@2` task (or omitted where install is fast) |
| `actions/delete-package-versions` | `gh api` calls to GitHub Packages REST API |
| `awalsh128/cache-apt-pkgs-action` | `sudo apt-get install` |
| `if: failure()` | `condition: failed()` |
| `if: always()` | `condition: always()` |
| `id-token: write` (OIDC) | AWS service connection or workload identity federation |

### Multi-Architecture Builds

GitHub Actions offers hosted ARM runners (`ubuntu-24.04-arm`). Azure DevOps does
**not** have hosted ARM agents. All ARM builds require a self-hosted agent pool
with ARM64 machines, configured via the `pool_arm` parameter.

Because Azure Pipelines cannot dynamically select agent pools from matrix
outputs, multi-arch builds are always split into two explicit parallel stages
(e.g. `test_suite_x86` / `test_suite_arm64`) rather than using a matrix. Both
stages depend on the same upstream stage (or have no `dependsOn` at all), so
they execute in parallel.

Exception: `ghcr-build-push.yml` uses QEMU on a single amd64 runner for
multi-platform builds (`linux/amd64,linux/arm64`), avoiding the need for ARM
agents.

### Secrets and Variables

Each template expects one or two variable groups:

1. **Secrets group** — contains sensitive values (PATs, passwords, keys).
   Linked to the pipeline or backed by Azure Key Vault.
2. **Vars group** (where applicable) — contains non-secret configuration values
   (URLs, regions).

The variable group names are configurable via `secrets_variable_group` and
`vars_variable_group` parameters with sensible defaults.

### Template Header Convention

Every template in `shared/` starts with a comment block documenting:

1. The source GitHub Actions workflow it was ported from
2. Prerequisites and required variable group contents
3. Agent pool requirements
4. Tools required on agents
5. Key differences from the GitHub Actions version

## How to Use

### 1. Set up variable groups

Create the required variable groups in your Azure DevOps project under
**Pipelines → Library**. Each template's header documents the exact variables
needed.

### 2. Set up agent pools

For x86 builds, the default Microsoft-hosted `ubuntu-24.04` image works. For
ARM builds, create a self-hosted agent pool with ARM64 machines.

### 3. Reference the templates

In your consuming repository, create an `azure-pipelines.yml` that references
the shared templates repository and extends from the desired template. See the
`*-pipeline.yml` files at the root of this directory for examples.

```yaml
resources:
  repositories:
    - repository: shared-templates
      type: git
      name: 'YourProject/shared-workflows'
      ref: refs/heads/main

extends:
  template: shared/build-push.yml@shared-templates
  parameters:
    docker_build_context: '.'
    # ... other parameters
```

### 4. Configure triggers

Unlike GitHub Actions where triggers are defined in the reusable workflow,
Azure Pipelines triggers are defined in the consuming pipeline. Set up
`trigger:` and optionally `pr:` blocks in your consumer pipeline.

### 5. Consolidated templates

Some GitHub Actions workflows were consolidated during porting:

- **`angular-build.yml` + `solidjs.yml`** → `shared/frontend-build.yml`
  These two workflows were byte-for-byte identical (only the workflow name
  differed). They are now a single template with separate consumer pipelines
  (`angular-build-pipeline.yml` and `solidjs-pipeline.yml`).

### 6. Non-portable workflows

- **`opencode.yml`** — Triggered by PR comments containing `/oc` or
  `/opencode` via the `issue_comment` event. Azure Pipelines has no equivalent
  to comment-triggered workflows. This would require an Azure DevOps Service
  Hook + Azure Function or similar external integration.
