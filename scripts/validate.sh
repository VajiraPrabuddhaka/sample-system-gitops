#!/usr/bin/env bash
# Static checks, no cluster needed (CI runs this on every PR).
#
#   1. kustomize builds every directory in flux/ (load restrictor off, as Flux does) and
#      argocd/ (default restrictor, as Argo CD does)
#   2. scripts/check-tree.py: the two trees hold identical values/manifests, the same
#      units, and every path, dependsOn and patch target a cluster uses exists
#   3. every pinned version matches versions.yaml, in both trees
#   4. (kubeconform) schema-validates the rendered manifests, CRDs included
#   5. (helm + PyYAML) renders, for every cluster, each OpenChoreo plane chart it installs
#      and each observability module or collector it gives values to, with the merged
#      values, so a typo in values fails here instead of in the cluster
#   6. lists REPLACE_ME placeholders (the Git source until the repo has a home)
#
# Usage: scripts/validate.sh [--strict] [--charts-dir DIR]
#   --strict       fail on placeholders too
#   --charts-dir   use local OpenChoreo plane charts (e.g. an openchoreo checkout's
#                  install/helm) instead of pulling the pinned versions from cr.openchoreo.dev
source "$(dirname "$0")/lib.sh"
need python3
command -v kustomize >/dev/null 2>&1 || need kubectl
strict=false; charts_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict) strict=true; shift ;;
    --charts-dir) charts_dir="$2"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
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
# chart_of <component>: "<chart> <versions.yaml key>" for the charts rendered here.
chart_of() {
  case "$1" in
    control-plane|data-plane|workflow-plane|observability-plane) echo "openchoreo-$1 $1" ;;
    obs-logs-opensearch|collector-logs-opensearch) echo "observability-logs-opensearch obs-logs-opensearch" ;;
    obs-traces-opensearch|collector-traces-opensearch) echo "observability-tracing-opensearch obs-traces-opensearch" ;;
    obs-metrics-prometheus|collector-metrics-prometheus) echo "observability-metrics-prometheus obs-metrics-prometheus" ;;
    obs-events-otel-collector|collector-events-otel-collector) echo "observability-events-otel-collector obs-events-otel-collector" ;;
  esac
}
if command -v helm >/dev/null 2>&1 && has_yaml; then
  while IFS= read -r units; do
    cdir="$(dirname "$units")"; cl="${cdir#flux/clusters/}"
    comps=()
    for comp in control-plane data-plane workflow-plane observability-plane; do
      grep -q "path: ./flux/planes/${comp}/install$" "$units" && comps+=("$comp")
    done
    for f in "$cdir"/values/*.yaml; do
      comp="$(basename "$f" .yaml)"
      case "$comp" in obs-*|collector-*) [[ -n "$(chart_of "$comp")" ]] && comps+=("$comp") ;; esac
    done
    for comp in "${comps[@]}"; do
      read -r chart vkey <<< "$(chart_of "$comp")"
      out="$tmp/values-$(echo "$cl" | tr '/' '_')-$comp.yaml"
      python3 scripts/render-values.py "$cl" "$comp" > "$out"
      if [[ -n "$charts_dir" && "$chart" == openchoreo-* ]]; then src=("$charts_dir/$chart")
      else src=("oci://cr.openchoreo.dev/openchoreo/helm-charts/$chart" --version "$(version_of "$vkey")"); fi
      if helm template "$chart" "${src[@]}" -f "$out" > /dev/null 2> "$tmp/err"; then
        info "ok   $cl/$comp"
      else
        warn "$cl/$comp:"; cat "$tmp/err" >&2; fail=1
      fi
    done
  done < <(find flux/clusters -name units.yaml | sort)
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
