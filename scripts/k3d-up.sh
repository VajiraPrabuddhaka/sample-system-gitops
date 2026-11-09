#!/usr/bin/env bash
# Create the local k3d cluster(s) for an example, with the same cluster definitions as
# OpenChoreo's k3d guides (ports 8080/19080/11080/... mapped to the host).
#
# Usage: scripts/k3d-up.sh [single|multi]
#   single (default)  one cluster "openchoreo" for clusters/k3d-single (scripts/k3d-config.yaml)
#   multi             four clusters for clusters/k3d-multi (scripts/k3d-multi/config-*.yaml):
#                     openchoreo-cp, openchoreo-dp, openchoreo-wp, openchoreo-op. The
#                     control-plane cluster also maps port 8200, where the other clusters
#                     reach the shared trust OpenBao (clusters/k3d-multi/k3d/openbao-trust).
# Then install Flux or Argo CD from their own guides and plug this repo in (README.md).
source "$(dirname "$0")/lib.sh"
need k3d docker kubectl

mode="${1:-single}"
case "$mode" in
  single|multi) ;;
  -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
  *) die "unknown mode '$mode' (single or multi)" ;;
esac

# Colima's DNS breaks k3d's DNS fix (k3d-io/k3d#1449).
if docker info --format '{{.Name}}' 2>/dev/null | grep -qi colima; then
  info "Colima detected: K3D_FIX_DNS=0"
  export K3D_FIX_DNS=0
fi

# up <config> [extra k3d args]: create the cluster unless it exists, give its nodes a
# machine-id (Fluent Bit needs /etc/machine-id; k3d nodes don't have one), print its name.
up() {
  local config="$1"; shift
  local name
  name="$(awk '/^metadata:/ {m=1; next} m && /^[[:space:]]+name:/ {print $2; exit}' "$config")"
  if k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$name"; then
    log "k3d cluster '$name' already exists"
  else
    log "creating k3d cluster '$name'"
    k3d cluster create --config "$config" "$@" >&2
  fi
  local node
  for node in $(docker ps --format '{{.Names}}' | grep -E "^k3d-${name}-(server|agent)-[0-9]+$"); do
    docker exec "$node" sh -c \
      "[ -s /etc/machine-id ] || cat /proc/sys/kernel/random/uuid | tr -d '-' > /etc/machine-id"
  done
  NAME="$name"
}

if [[ "$mode" == single ]]; then
  up "$ROOT/scripts/k3d-config.yaml"
  kubectl config use-context "k3d-${NAME}" >/dev/null
  log "kube context: k3d-${NAME}"
  info "next: install Flux or Argo CD, then plug this repo in (README.md, Quick start)"
  exit 0
fi

# Four k3s servers need more inotify instances than Docker's VM usually allows
# (upstream: "too many open files" otherwise).
limit="$(docker run --rm alpine cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)"
if [[ "$limit" =~ ^[0-9]+$ ]] && (( limit > 0 && limit < 1024 )); then
  warn "fs.inotify.max_user_instances is ${limit}; four clusters need more. Raise it first:"
  info "docker run --rm --privileged alpine sysctl -w fs.inotify.max_user_instances=1024"
  info "docker run --rm --privileged alpine sysctl -w fs.inotify.max_user_watches=524288"
fi

contexts=()
for c in cp dp wp op; do
  extra=()
  [[ "$c" == cp ]] && extra=(--port "8200:8200@loadbalancer")
  up "$ROOT/scripts/k3d-multi/config-$c.yaml" "${extra[@]}"
  contexts+=("k3d-${NAME}")
done
kubectl config use-context k3d-openchoreo-cp >/dev/null
log "kube contexts: ${contexts[*]} (current: k3d-openchoreo-cp)"
info "next: install Flux or Argo CD on each cluster, then plug each one in (README.md, k3d-multi)"
