# AGENTS.md

## Project Overview

This repository (`misc-testing/azure/workflows`) contains Azure Pipelines
templates ported from GitHub Actions reusable workflows. The templates live in
`shared/` and sample consumer pipelines live at the root. There is no
application code, no build system, and no tests — only YAML pipeline
definitions.

## Repository Structure

```
workflows/
  .opencode/skills/port-gh-workflow/SKILL.md   # Agent skill for porting workflows
  shared/                                       # Reusable Azure Pipelines templates
    build-push.yml                              # Docker multi-arch build + ECR push
    docker-build.yml                            # Docker test build, optional GHCR push
    frontend-build.yml                          # Frontend (Angular/SolidJS) build + test
    generic-no-buildtarget.yml                  # Generic Docker test suite (no target)
    ghcr-build-push.yml                         # Multi-arch Docker via QEMU + GHCR push
    helm-chart.yml                              # Helm lint (ct), kubeconform, unit tests
    java.yml                                    # Java Docker-compose test + Spectral
    packages.yml                                # GitHub Packages version cleanup
    python.yml                                  # Python test suite (lint, test, coverage)
    python-wheel.yml                            # Python wheel build + devpi upload
    webhook-only.yml                            # Deployment webhook + Slack notification
  angular-build-pipeline.yml                    # Angular consumer for frontend-build.yml
  build-push-pipeline.yml                       # Consumer for shared/build-push.yml
  docker-build-pipeline.yml                     # Consumer for shared/docker-build.yml
  frontend-build-pipeline.yml                   # Consumer for shared/frontend-build.yml
  generic-no-buildtarget-pipeline.yml           # Consumer for generic-no-buildtarget.yml
  ghcr-build-push-pipeline.yml                  # Consumer for shared/ghcr-build-push.yml
  helm-chart-pipeline.yml                       # Consumer for shared/helm-chart.yml
  java-pipeline.yml                             # Consumer for shared/java.yml
  packages-pipeline.yml                         # Consumer for shared/packages.yml
  python-pipeline.yml                           # Consumer for shared/python.yml
  python-wheel-pipeline.yml                     # Consumer for shared/python-wheel.yml
  solidjs-pipeline.yml                          # SolidJS consumer for frontend-build.yml
  webhook-only-pipeline.yml                     # Consumer for shared/webhook-only.yml
  README.md
```

## Build / Lint / Test

There is no build system or test suite. Validation is manual — paste YAML into
an Azure DevOps pipeline editor or use a YAML linter.

```bash
# Validate YAML syntax (requires yamllint)
yamllint shared/*.yml *-pipeline.yml

# Dry-run validation in Azure DevOps (requires az cli + extension)
az pipelines run --name <pipeline> --branch <branch> --parameters '{}' --dry-run
```

## Agent Skill

Before porting a GitHub Actions workflow, **always load the skill first**:

```
skill({ name: "port-gh-workflow" })
```

The skill at `.opencode/skills/port-gh-workflow/SKILL.md` contains the complete
porting reference: file structure, naming conventions, every GitHub Actions →
Azure Pipelines translation pattern, and the post-porting checklist. Follow it
precisely.

## File Naming Convention

| Location | Purpose | Example |
|---|---|---|
| `shared/<name>.yml` | Reusable template (`workflow_call` equivalent) | `shared/build-push.yml` |
| `<name>-pipeline.yml` | Sample consumer pipeline | `build-push-pipeline.yml` |

The base names must match between template and consumer.

## YAML Style Guide

### Formatting

- **2-space indentation**, no tabs.
- Multi-line strings use `|` (literal block scalar).
- String values: single quotes for `displayName`, unquoted or double quotes
  elsewhere. Booleans and numbers are unquoted.
- No trailing whitespace.

### Comment Conventions

```yaml
# =============================================================================
# Top-level file header (77-char bars)
# =============================================================================

  # ===========================================================================
  # Stage-level section header (75-char bars, indented to stage level)
  # ===========================================================================

          # -- Step description --          (inline step comment)

          # NOTE: Important callout.        (explanatory note)
```

### Naming Conventions

| Element | Case | Examples |
|---|---|---|
| Parameters | `snake_case` | `docker_build_context`, `pool_arm` |
| Stages | `snake_case` | `image_push_amd64`, `test_suite_x86` |
| Jobs | `snake_case` | `build_amd64`, `set_vars` |
| Step `name:` | `snake_case` | `check_tag`, `deploy_vars` |
| Variable groups | `kebab-case` | `moya-build-push-secrets` |
| Pipeline variables | `UPPER_SNAKE_CASE` | `IMAGE_TAG`, `GHCR_REPO` |
| Step output vars | `snake_case` | `ref_type`, `ecr_cache_url` |
| `displayName:` | Sentence case, single-quoted | `'Build test image'` |

Architecture suffixes use `_x86` / `_arm64` / `_amd64` on stage and job names.

### Template File Structure (strict order)

1. **Header comment block** — source workflow, prerequisites (variable groups,
   agent pools, tools), differences from GitHub Actions version.
2. **`parameters:`** — workflow inputs first, then Azure-specific params. Two
   groups separated by `# --- Equivalent to ...` / `# --- Additional ...`.
3. **`variables:`** — variable group references, then computed variables.
4. **`stages:`** — one stage per original GitHub Actions job.

### Consumer Pipeline Structure (strict order)

1. Header comment block (source workflow, usage instructions).
2. `trigger:` block.
3. `resources.repositories:` referencing `shared-templates`.
4. `extends:` with `template:` and `parameters:`.

### Bash Steps

- Start non-trivial scripts with `set -euo pipefail`.
- Assign pipeline variables to local shell variables at the top for readability:
  ```yaml
  - bash: |
      set -euo pipefail
      GHCR_REPO="$(GHCR_REPO)"
      NEW_TAG="$(set_tag.new_tag)"
      # ... use local vars below
  ```
- Export outputs: `echo "##vso[task.setvariable variable=NAME;isOutput=true]VALUE"`
- Report errors: `echo "##vso[task.logissue type=error]msg"` then `exit 1`.
- Pass secrets via `env:` blocks on the step, never inline in the script body.
- Every bash step must have a `displayName:`. Steps producing outputs must also
  have a `name:`.

### Multi-Architecture Pattern

- Never use `strategy.matrix` when different entries need different agent pools.
- Split into separate parallel stages (`_x86` + `_arm64`).
- Stages with the same `dependsOn` and no mutual dependency run in parallel.
- x86 uses `pool: { vmImage: '...' }` (hosted). ARM uses `pool: { name: '...' }`
  (self-hosted).
- Check for both `"True"` and `"true"` when comparing boolean parameters at
  runtime (Azure normalizes inconsistently).

### Cross-Stage Variable References

```yaml
# Stage-level variable from upstream stage output:
variables:
  MY_VAR: $[ stageDependencies.<stage>.<job>.outputs['<step>.varName'] ]

# Condition referencing upstream output:
condition: eq(stageDependencies.<stage>.<job>.outputs['<step>.varName'], 'value')

# Allow skipped upstream stages:
condition: in(stageDependencies.<stage>.result, 'Succeeded', 'Skipped')
```

## Post-Porting Checklist

After porting any new GitHub Actions workflow:

1. Update the **Porting Status** table in `README.md`.
2. Verify all secrets/variables are documented in the template header.
3. Confirm parallel stages have correct `dependsOn` (shared upstream, no
   mutual dependency).
4. Ensure ARM stages install any tools missing from self-hosted agents.
