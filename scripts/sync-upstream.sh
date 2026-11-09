#!/usr/bin/env bash
# Re-copy the files this repo vendors from openchoreo/openchoreo at a release tag, keeping
# each file's header comment. Every vendored file lives in both engine trees (flux/ and
# argocd/), so each is written twice. Run it when bumping OpenChoreo,
# then review `git diff`. Files derived by hand (the k3d plane values, and k3d-multi's
# trust OpenBao and OpenSearch route) are not touched: compare them with the upstream
# guides yourself.
#
# Usage: scripts/sync-upstream.sh <tag>      e.g. scripts/sync-upstream.sh v1.4.0
source "$(dirname "$0")/lib.sh"
need git python3
tag="${1:-}"; [[ -n "$tag" ]] || die "tag required, e.g. v1.4.0"

# destination|upstream path. "@/" = in both flux/ and argocd/.
map="@/planes/workflow-plane/templates/manifests/checkout-source.yaml|samples/getting-started/workflow-templates/checkout-source.yaml
@/planes/workflow-plane/templates/manifests/build-templates.yaml|samples/getting-started/workflow-templates.yaml
@/clusters/k3d-single/k3d/workflow-templates/manifests/publish-image-k3d.yaml|samples/getting-started/workflow-templates/publish-image-k3d.yaml
@/clusters/k3d-single/k3d/workflow-templates/manifests/generate-workload-k3d.yaml|samples/getting-started/workflow-templates/generate-workload-k3d.yaml
@/clusters/k3d-single/k3d/coredns/manifests/coredns-custom.yaml|install/k3d/common/coredns-custom.yaml
@/clusters/k3d-single/k3d/openbao/values.yaml|install/k3d/common/values-openbao.yaml
@/clusters/k3d-single/values/thunder.yaml|install/k3d/common/values-thunder.yaml
scripts/k3d-config.yaml|install/k3d/single-cluster/config.yaml
@/clusters/k3d-multi/k3d/workflow-templates/manifests/publish-image-k3d.yaml|samples/getting-started/workflow-templates/publish-image-k3d.yaml
@/clusters/k3d-multi/k3d/workflow-templates/manifests/generate-workload-k3d.yaml|samples/getting-started/workflow-templates/generate-workload-k3d.yaml
@/clusters/k3d-multi/k3d/coredns/manifests/coredns-custom.yaml|install/k3d/common/coredns-custom.yaml
@/clusters/k3d-multi/k3d/openbao/values.yaml|install/k3d/common/values-openbao.yaml
@/clusters/k3d-multi/control-plane/values/thunder.yaml|install/k3d/common/values-thunder.yaml
scripts/k3d-multi/config-cp.yaml|install/k3d/multi-cluster/config-cp.yaml
scripts/k3d-multi/config-dp.yaml|install/k3d/multi-cluster/config-dp.yaml
scripts/k3d-multi/config-wp.yaml|install/k3d/multi-cluster/config-wp.yaml
scripts/k3d-multi/config-op.yaml|install/k3d/multi-cluster/config-op.yaml"

src="$(mktemp -d)"; trap 'rm -rf "$src"' EXIT
log "fetching openchoreo/openchoreo@${tag}"
git -C "$src" init -q
git -C "$src" remote add origin https://github.com/openchoreo/openchoreo.git
git -C "$src" config core.sparseCheckout true
printf 'install/k3d/\nsamples/getting-started/\n' > "$src/.git/info/sparse-checkout"
git -C "$src" fetch -q --depth 1 origin tag "$tag"
git -C "$src" checkout -q "$tag"

# sync <dest> <upstream>: our header (the dest's leading comments, minus the upstream
# file's own leading comments, which follow it) + the upstream file at $tag.
sync() {
  python3 - "$ROOT/$1" "$src/$2" "$tag" <<'PY'
import re, sys
dest, up, tag = sys.argv[1:]
def lead(lines):
    n = 0
    while n < len(lines) and lines[n].startswith("#"):
        n += 1
    return lines[:n]
mine, theirs = open(dest).read().split("\n"), open(up).read()
ours, upstream = lead(mine), lead(theirs.split("\n"))
if upstream and ours[-len(upstream):] == upstream:
    ours = ours[:-len(upstream)]
elif upstream:
    print(f"WARNING: {dest}: upstream's leading comments changed; check the header by hand", file=sys.stderr)
ours = [re.sub(r"@v[0-9][^:]*:", f"@{tag}:", l) for l in ours]
open(dest, "w").write("\n".join(ours) + "\n" + theirs)
PY
  info "synced $1"
}
while IFS='|' read -r dest up; do
  [[ -f "$src/$up" ]] || { warn "missing upstream $up at $tag"; continue; }
  if [[ "$dest" == @/* ]]; then
    for engine in flux argocd; do sync "$engine/${dest#@/}" "$up"; done
  else
    sync "$dest" "$up"
  fi
done <<< "$map"
log "done. Review: git diff -- flux argocd scripts/k3d-config.yaml scripts/k3d-multi"
info "also bump versions.yaml and run scripts/versions.py apply"
