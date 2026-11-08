# shellcheck shell=bash
# Shared helpers for scripts/*.sh. Source it; don't run it.
# No `set -u`: macOS ships bash 3.2, where expanding an empty array trips it.
set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need() {
  local t
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"; done
}

# version_of <key>: read a pin from versions.yaml (flat "  key: \"value\"" lines).
version_of() {
  sed -n "s/^[[:space:]]*$1:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$ROOT/versions.yaml" | head -1
}

# git_https_url: origin of this checkout as an https URL (Flux/Argo CD pull over https).
git_https_url() {
  local url
  url="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" || die "no git remote 'origin'; pass --repo"
  case "$url" in
    git@*:*) url="https://${url#git@}"; url="${url/://}" ;;
    ssh://git@*) url="https://${url#ssh://git@}" ;;
  esac
  printf '%s\n' "$url"
}

git_branch() { git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main; }

# warn_unpushed: GitOps controllers read the remote, not this checkout.
warn_unpushed() {
  if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
    warn "uncommitted changes in $ROOT: the cluster only sees what is pushed"
  fi
  if git -C "$ROOT" rev-parse '@{u}' >/dev/null 2>&1 && [[ -n "$(git -C "$ROOT" log '@{u}..' --oneline 2>/dev/null)" ]]; then
    warn "local commits not pushed to $(git -C "$ROOT" rev-parse --abbrev-ref '@{u}')"
  fi
}

# kbuild [args] <dir>: kustomize build, falling back to the copy built into kubectl.
kbuild() {
  if command -v kustomize >/dev/null 2>&1; then kustomize build "$@"; else kubectl kustomize "$@"; fi
}
