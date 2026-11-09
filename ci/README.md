# CI workflows (move into .github/workflows)

These are the repo's GitHub Actions workflows. They were written here because the tool
that created this repo isn't allowed to write into `.github/workflows/`. Enable them with:

```bash
mkdir -p .github/workflows
git mv ci/github-workflows/validate.yaml ci/github-workflows/e2e-k3d.yaml .github/workflows/ 2>/dev/null \
  || mv ci/github-workflows/*.yaml .github/workflows/
rm -r ci
```

- `validate.yaml`: static checks on every PR (`scripts/validate.sh`).
- `e2e-k3d.yaml`: manual end-to-end run on k3d: installs Flux, applies
  `flux/clusters/k3d-single/plug.yaml` for the branch, waits for every registration.
  `k3d-multi` gets the static checks only: four clusters with observability don't fit a
  hosted runner.
