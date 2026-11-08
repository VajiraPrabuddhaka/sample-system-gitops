#!/usr/bin/env bash
# Show where an install stands: unit status (Flux Kustomizations or Argo CD Applications),
# the trust relay, plane registration and unhealthy pods. Exits non-zero while any
# registered plane's agent is disconnected.
#
# Usage: scripts/verify.sh [--context CONTEXT]
source "$(dirname "$0")/lib.sh"
need kubectl
ctx=()
[[ "${1:-}" == "--context" ]] && ctx=(--context "$2")
k() { kubectl "${ctx[@]}" "$@"; }
has_crd() { k get crd "$1" >/dev/null 2>&1; }

if has_crd kustomizations.kustomize.toolkit.fluxcd.io; then
  log "Flux units (openchoreo-*)"
  k -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io
  log "Flux Helm releases"
  k -n flux-system get helmreleases.helm.toolkit.fluxcd.io
fi
if has_crd applications.argoproj.io; then
  log "Argo CD applications"
  k -n argocd get applications.argoproj.io -o custom-columns='NAME:.metadata.name,WAVE:.metadata.annotations.argocd\.argoproj\.io/sync-wave,SYNC:.status.sync.status,HEALTH:.status.health.status' --sort-by='.metadata.annotations.argocd\.argoproj\.io/sync-wave'
fi
if has_crd pushsecrets.external-secrets.io; then
  log "Trust relay and secrets (READY=False means the other side has not published yet)"
  k get clustersecretstores.external-secrets.io 2>/dev/null || true
  k get pushsecrets.external-secrets.io -A 2>/dev/null || true
  k get externalsecrets.external-secrets.io -A 2>/dev/null || true
fi

rc=0
if has_crd clusterdataplanes.openchoreo.dev; then
  log "Plane registrations (this is the control-plane cluster)"
  cols='NAME:.metadata.name,PLANE_ID:.spec.planeID,CONNECTED:.status.agentConnection.connected,AGENTS:.status.agentConnection.connectedAgents,MESSAGE:.status.agentConnection.message'
  for kind in clusterdataplanes clusterworkflowplanes clusterobservabilityplanes; do
    out="$(k get "$kind.openchoreo.dev" -o custom-columns="$cols" 2>/dev/null || true)"
    [[ -n "$out" ]] || continue
    printf '%s\n%s\n' "$kind" "$out"
    if printf '%s\n' "$out" | tail -n +2 | awk '$3 != "true"' | grep -q .; then rc=1; fi
  done
fi

log "Pods not Running/Completed in OpenChoreo and add-on namespaces"
k get pods -A --no-headers 2>/dev/null \
  | awk '$1 ~ /^(openchoreo-|thunder|openbao|external-secrets|cert-manager|kgateway-system|flux-system|argocd)/ && $4 != "Running" && $4 != "Completed"' \
  || true

if [[ $rc -ne 0 ]]; then
  warn "some plane agents are not connected yet"
fi
exit $rc
