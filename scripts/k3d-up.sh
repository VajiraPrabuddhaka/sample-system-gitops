#!/usr/bin/env bash
# Create the local k3d cluster for the k3d-single example (the same cluster definition as
# OpenChoreo's k3d guide: ports 8080/19080/11080/... mapped to the host).
#
# Usage: scripts/k3d-up.sh
# Then install Flux or Argo CD from their own guides and plug this repo in (README.md).
source "$(dirname "$0")/lib.sh"
need k3d docker kubectl

CONFIG="$ROOT/scripts/k3d-config.yaml"
NAME="$(awk '/^metadata:/ {m=1; next} m && /^[[:space:]]+name:/ {print $2; exit}' "$CONFIG")"

if k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$NAME"; then
  log "k3d cluster '$NAME' already exists"
else
  # Colima's DNS breaks k3d's DNS fix (k3d-io/k3d#1449).
  if docker info --format '{{.Name}}' 2>/dev/null | grep -qi colima; then
    info "Colima detected: K3D_FIX_DNS=0"
    export K3D_FIX_DNS=0
  fi
  log "creating k3d cluster '$NAME'"
  k3d cluster create --config "$CONFIG"
fi

# Fluent Bit (logs module) needs /etc/machine-id, which k3d nodes don't have.
for node in $(docker ps --format '{{.Names}}' | grep -E "^k3d-${NAME}-(server|agent)-[0-9]+$"); do
  docker exec "$node" sh -c \
    "[ -s /etc/machine-id ] || cat /proc/sys/kernel/random/uuid | tr -d '-' > /etc/machine-id"
done

kubectl config use-context "k3d-${NAME}" >/dev/null
log "kube context: k3d-${NAME}"
info "next: install Flux or Argo CD, then plug this repo in (README.md, Quick start)"
