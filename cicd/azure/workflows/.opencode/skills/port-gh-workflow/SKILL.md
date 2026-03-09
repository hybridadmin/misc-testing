---
name: port-gh-workflow
description: Port a GitHub Actions reusable workflow (workflow_call) to an Azure Pipelines template, following the established file structure, naming conventions, and porting patterns in this repository.
---

## What I Do

I port GitHub Actions reusable workflows (`workflow_call`) to Azure Pipelines templates. I follow the exact conventions established in this repository and produce two files per workflow:

1. A **reusable template** in `shared/<name>.yml`
2. A **sample consumer pipeline** at `<name>-pipeline.yml`

## File and Folder Structure

Strictly follow this layout:

```
workflows/
  shared/                          # Reusable templates only
    <name>.yml                     # Template file (equivalent to workflow_call)
  <name>-pipeline.yml              # Sample consumer pipeline
  README.md                        # Update porting status table
```

- Template files go in `shared/`. Never put consumer pipelines here.
- Consumer pipelines go at the repository root. Never put templates here.
- The template and consumer use matching base names (e.g. `shared/build-push.yml` and `build-push-pipeline.yml`).

## Template File Structure

Every template in `shared/` must follow this structure in order:

### 1. Header Comment Block

```yaml
# =============================================================================
# Azure Pipelines Template: <descriptive-name>
# =============================================================================
# Ported from: .github/workflows/<original-name>.yml (GitHub Actions reusable workflow)
#
# This is an Azure Pipelines *template* file. ...
#
# ----- PREREQUISITES / SETUP -----
#
# 1. Variable Group: "<name>-secrets"
#    Create a variable group (or link an Azure Key Vault) containing:
#      - VAR_NAME : Description
#
# 2. Variable Group: "<name>-vars"
#    Non-secret variables:
#      - VAR_NAME : Description
#
# 3. Agent Pools:
#    - ...
#
# 4. Tools required on agents:
#    - ...
#
# ----- DIFFERENCES FROM GITHUB ACTIONS VERSION -----
#
# - Bullet list of key differences
# =============================================================================
```

### 2. Parameters

Map every GitHub Actions `workflow_call` input to a parameter. Add Azure-specific parameters at the end (variable group names, GHCR repository, etc.):

```yaml
parameters:
  # --- Equivalent to GitHub Actions workflow_call inputs ---
  - name: <name>
    type: string|boolean|number
    displayName: '<description>'
    default: '<value>'

  # --- Additional parameters (Azure-specific) ---
  - name: secrets_variable_group
    type: string
    displayName: 'Variable group name containing secrets'
    default: '<name>-secrets'
```

### 3. Variables

Reference variable groups and define computed variables:

```yaml
variables:
  - group: ${{ parameters.secrets_variable_group }}
  - group: ${{ parameters.vars_variable_group }}
```

### 4. Stages

Map GitHub Actions jobs to Azure Pipelines stages.

## Consumer Pipeline File Structure

Every consumer pipeline must follow this structure:

```yaml
# =============================================================================
# Sample Azure Pipeline that consumes the <name> template
# =============================================================================
# This is the equivalent of a GitHub Actions workflow that calls the reusable
# workflow via `uses: org/shared-workflows/.github/workflows/<name>.yml`.
#
# Place this file in the consuming repository as `azure-pipelines.yml` and
# adjust the resource reference to point to your shared templates repo.
# =============================================================================

trigger:
  # appropriate triggers

resources:
  repositories:
    - repository: shared-templates
      type: git
      name: 'YourProject/shared-workflows'
      ref: refs/heads/main
      # endpoint: 'your-github-service-connection'  # Only needed for GitHub repos

extends:
  template: shared/<name>.yml@shared-templates
  parameters:
    # all parameters with comments showing defaults
```

## Porting Rules

Follow these rules precisely when converting GitHub Actions concepts:

### Jobs and Stages

- Each GitHub Actions `job` becomes an Azure Pipelines `stage` containing one `job`.
- `needs:` becomes `dependsOn:`.
- `if:` conditions on jobs become `condition:` on stages.
- `timeout-minutes:` becomes `timeoutInMinutes:` on the job.

### Matrix Strategies

- **Never** use Azure Pipelines `strategy.matrix` when different matrix entries need different agent pools.
- Instead, split into separate parallel stages (e.g. `<name>_x86` and `<name>_arm64`).
- Stages that share the same `dependsOn` and have no dependency on each other run in parallel automatically.
- Dynamic matrices (GitHub's `fromJSON()` from job outputs) are impossible in Azure Pipelines. Always use separate conditional stages.

### Variables and Outputs

- `${{ github.* }}` context maps to Azure predefined variables:
  - `github.repository` → `$(Build.Repository.Name)`
  - `github.ref` / `github.sha` → `$(Build.SourceBranch)` / `$(Build.SourceVersion)`
  - `github.run_id` → `$(Build.BuildId)`
  - `github.server_url`/`github.repository`/actions/runs/`github.run_id` → `$(System.CollectionUri)$(System.TeamProject)/_build/results?buildId=$(Build.BuildId)`
- Step outputs (`>> $GITHUB_OUTPUT`) become `##vso[task.setvariable variable=NAME;isOutput=true]VALUE`.
- Cross-stage variable references use `stageDependencies.<stage>.<job>.outputs['<step>.varName']`.
- Job-level `env:` blocks referencing outputs from other jobs use stage-level `variables:` with `$[ stageDependencies... ]` syntax.

### Secrets and Variables

- `secrets.*` → variables from a variable group (secrets group).
- `vars.*` → variables from a variable group (non-secret group).
- Always parameterize variable group names with sensible defaults.
- Pass secrets to bash steps via `env:` blocks, never inline.

### GitHub Actions to Bash Replacements

- `actions/checkout@v5` → `checkout: self` with `submodules: recursive`, `persistCredentials: true`, and appropriate `fetchDepth`.
- `docker/login-action@v3` → `docker login` via bash with password piped via stdin.
- `docker/build-push-action@v6` → `docker buildx build` with equivalent flags (`--platform`, `--tag`, `--cache-from`, `--cache-to`, `--ssh`, `--build-arg`, `--secret`, `--output`, `--load`, `--target`).
- `docker/setup-buildx-action@v3` → `docker buildx create --use --name multiarch-builder || true && docker buildx inspect --bootstrap`.
- `timheuer/base64-to-file@v1.2` → `echo "$VAR" | base64 -d > "$PATH" && chmod 600 "$PATH"`.
- `aws-actions/configure-aws-credentials@v5` → `aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$URL"` with `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from env.
- `aws-actions/amazon-ecr-login@v2` → same as above (combined into one step).
- `actions/upload-artifact@v4` → `PublishPipelineArtifact@1` task.
- `actions/download-artifact@v4` → `DownloadPipelineArtifact@2` task, followed by a flatten step if merging multiple artifacts.
- `slackapi/slack-github-action@v2` → `curl -s -X POST -H 'Content-type: application/json' --data '...' "$WEBHOOK_URL"`.
- `astral-sh/setup-uv@v6` → `curl -LsSf https://astral.sh/uv/install.sh | sh && echo "##vso[task.prependpath]$HOME/.local/bin"`.
- `pypa/cibuildwheel@v3` → `pip install cibuildwheel && cibuildwheel --output-dir wheelhouse "$PKG_DIR"` with `CIBW_*` env vars.

### Conditions

- `if: failure()` → `condition: failed()`.
- `if: always()` → `condition: always()`.
- `if: ${{ needs.foo.outputs.bar == 'baz' }}` → `condition: eq(stageDependencies.foo.job_name.outputs['step.bar'], 'baz')`.
- Compound conditions use `and()`, `or()`, `not()`, `eq()`, `ne()`, `in()`.
- Use `in(stageDependencies.<stage>.result, 'Succeeded', 'Skipped')` when a stage should run even if an optional upstream was skipped.

### ARM Builds

- Azure DevOps has no hosted ARM agents.
- ARM stages must use `pool: { name: '${{ parameters.pool_arm }}' }` pointing to a self-hosted pool.
- Install tools that may be missing on self-hosted agents (e.g. yq: download `yq_linux_arm64`).
- x86 stages can use `pool: { vmImage: '${{ parameters.pool_x86 }}' }` for Microsoft-hosted agents.

### Bash Steps

- Always use `set -euo pipefail` at the top of bash scripts.
- Always give every step a `displayName:`.
- Use `name:` on steps that produce output variables.
- Prefer assigning pipeline variables to local shell variables at the top of the script for readability.
- Use `echo "##vso[task.logissue type=error]message"` followed by `exit 1` for explicit failures.

## After Porting

1. Update the **Porting Status** table in `README.md` to mark the workflow as ported.
2. Review all secret/variable references to ensure they are documented in the template header.
3. Verify that parallel stages have correct `dependsOn` relationships (stages with the same upstream and no mutual dependency run in parallel).
