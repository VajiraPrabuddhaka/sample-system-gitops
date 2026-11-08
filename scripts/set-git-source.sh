#!/usr/bin/env bash
# Point both engines at the repo (and branch) your clusters should pull from: your fork,
# a mirror, or wherever this repo lives. Rewrites
#   - flux/clusters/*/plug.yaml           GitRepository url + branch
#   - argocd/**/*.yaml                    every repoURL/targetRevision pointing at this repo
# Commit and push the result before plugging a cluster in: the engines read the remote.
#
# Usage: scripts/set-git-source.sh [REPO_URL] [BRANCH]
#   defaults: this checkout's origin (as https) and the current branch
source "$(dirname "$0")/lib.sh"
repo="${1:-$(git_https_url)}"
branch="${2:-$(git_branch)}"

root_app="$(ls "$ROOT"/argocd/clusters/*/root-app.yaml | head -1)"
current="$(sed -n 's/^[[:space:]]*repoURL:[[:space:]]*//p' "$root_app" | head -1)"
[[ -n "$current" ]] || die "could not read the current repo URL from $root_app"
log "repo:   ${current} -> ${repo}"
log "branch: -> ${branch}"

rewrite() { # file awk-program
  awk -v old="$current" -v new="$repo" -v br="$branch" "$2" "$1" > "$1.tmp"
  if ! cmp -s "$1" "$1.tmp"; then mv "$1.tmp" "$1"; count=$((count + 1)); else rm -f "$1.tmp"; fi
}
count=0
# Argo CD: the repoURL line and the targetRevision right after it, for this repo only.
while IFS= read -r f; do
  rewrite "$f" '
    mine && $1 == "targetRevision:" { sub(/targetRevision: .*/, "targetRevision: " br) }
    { mine = 0 }
    index($0, "repoURL: " old) > 0 { sub("repoURL: " old, "repoURL: " new); mine = 1 }
    { print }'
done < <(find "$ROOT/argocd" -name '*.yaml')
# Flux: the GitRepository url and the branch under ref.
while IFS= read -r f; do
  rewrite "$f" '
    index($0, "url: " old) > 0 { sub("url: " old, "url: " new) }
    $1 == "branch:" { sub(/branch: .*/, "branch: " br) }
    { print }'
done < <(find "$ROOT/flux/clusters" -name plug.yaml)
log "updated ${count} files. Commit and push them, then plug a cluster in (README.md)."
