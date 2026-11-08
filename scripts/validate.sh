#!/usr/bin/env bash
# Static checks, no cluster needed (CI runs this on every PR).
#
#   1. kustomize builds every directory in flux/ (load restrictor off, as Flux does) and
#      argocd/ (default restrictor, as Argo CD does)
#   2. scripts/check-tree.py: the two trees hold identical values/manifests, the same
#      units, and every path, dependsOn and patch target a cluster uses exists
#   3. every pinned version matches versions.yaml, in both trees
#   4. (kubeconform) schema-validates the rendered manifests, CRDs included
#   5. (helm + PyYAML) renders each OpenChoreo chart with every cluster's merged values,
#      so a typo in values fails here instead of in the cluster
#   6. lists REPLACE_ME placeholders (the Git source until the repo has a home)
#
# Usage: scripts/validate.sh [--strict] [--charts-dir DIR]
#   --strict       fail on placeholders too
#   --charts-dir   use local charts (e.g. an openchoreo checkout's install/helm) instead of
#                  pulling the pinned versions from cr.openchoreo.dev
source "$(dirname "$0")/lib.sh"
need python3
command -v kustomize >/dev/null 2>&1 || need kubectl
strict=false; charts_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict) strict=true; shift ;;
    --charts-dir) charts_dir="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
cd "$ROOT"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
has_yaml() { python3 -c 'import yaml' 2>/dev/null; }

log "1/6 kustomize build"
n=0
while IFS= read -r d; do
  n=$((n + 1))
  name="$(echo "$d" | tr '/' '_')"
  args=(); [[ "$d" == flux/* ]] && args=(--load-restrictor LoadRestrictionsNone)
  if ! kbuild "${args[@]}" "$d" > "$tmp/$name.yaml" 2> "$tmp/err"; then
    warn "$d:"; cat "$tmp/err" >&2; fail=1
  fi
done < <(find flux argocd -name kustomization.yaml -exec dirname {} \; | sort)
info "built $n directories"

log "2/6 tree structure"
if has_yaml; then python3 scripts/check-tree.py || fail=1
else python3 scripts/check-tree.py || fail=1; info "(install PyYAML for the reference checks)"; fi

log "3/6 version pins"
python3 scripts/versions.py check || fail=1

log "4/6 kubeconform"
if command -v kubeconform >/dev/null 2>&1; then
  # CRD schemas: datreeio/CRDs-catalog (Flux, Argo CD, ESO, cert-manager) and, if present,
  # schemas generated from the OpenChoreo CRDs (KUBECONFORM_EXTRA_SCHEMAS, see ci/).
  if ! kubeconform -summary -strict -ignore-missing-schemas \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      ${KUBECONFORM_EXTRA_SCHEMAS:+-schema-location "$KUBECONFORM_EXTRA_SCHEMAS"} \
      "$tmp"/*.yaml; then fail=1; fi
else
  info "skipped (kubeconform not installed)"
fi

log "5/6 helm template OpenChoreo charts with merged values"
if command -v helm >/dev/null 2>&1 && has_yaml; then
  for cl in flux/clusters/*/; do
    cl="$(basename "$cl")"
    for comp in control-plane data-plane workflow-plane observability-plane; do
      grep -q "path: ./flux/planes/${comp}/install$" "flux/clusters/$cl/units.yaml" || continue
      python3 scripts/render-values.py "$cl" "$comp" > "$tmp/values-$cl-$comp.yaml"
      chart="openchoreo-$comp"
      if [[ -n "$charts_dir" ]]; then src=("$charts_dir/$chart")
      else src=("oci://cr.openchoreo.dev/openchoreo/helm-charts/$chart" --version "$(version_of "$comp")"); fi
      if helm template "$chart" "${src[@]}" -f "$tmp/values-$cl-$comp.yaml" > /dev/null 2> "$tmp/err"; then
        info "ok   $cl/$comp"
      else
        warn "$cl/$comp:"; cat "$tmp/err" >&2; fail=1
      fi
    done
  done
else
  info "skipped (needs helm and PyYAML)"
fi

log "6/6 placeholders"
found="$(grep -rhoE 'REPLACE_ME_[A-Z0-9_]+' flux argocd | sort -u | tr '\n' ' ')"
if [[ -n "$found" ]]; then
  info "to fill: ${found}(scripts/set-git-source.sh <your repo URL> [branch])"
  $strict && fail=1
else
  info "none"
fi

[[ $fail -eq 0 ]] && log "all checks passed" || die "validation failed"
