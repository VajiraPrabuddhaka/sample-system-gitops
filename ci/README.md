# CI Workflows

This directory contains the GitHub Actions workflows for this repository. They are kept here instead of `.github/workflows/` because the tool that created this repository is not allowed to write into `.github/workflows/`. To enable them, move them into place with the following commands:

```bash
mkdir -p .github/workflows
git mv ci/github-workflows/validate.yaml ci/github-workflows/e2e-k3d.yaml .github/workflows/ 2>/dev/null \
  || mv ci/github-workflows/*.yaml .github/workflows/
rm -r ci
```

## Available Workflows

- **`validate.yaml`** - Runs the static checks (`scripts/validate.sh`) on every PR and on every push to `main`.
- **`e2e-k3d.yaml`** - A manual end-to-end run on k3d. It installs Flux, applies `flux/clusters/k3d-single/plug.yaml` for the branch, and waits until every plane registration and then the platform defaults become Ready.

> [!NOTE]
> `k3d-multi` is covered only by the static checks. Four clusters with observability do not fit into a hosted runner.
