#!/usr/bin/env bash
# Write the secrets OpenChoreo's system components read into the secret store behind a
# cluster's ClusterSecretStore "default", before (or while) the GitOps engine syncs.
# This is the one piece of the install that cannot live in Git. Each cluster reads its
# own "default"; seed each one (with several clusters, give them the same OpenSearch
# credentials: collectors on other clusters write to the observability plane's
# OpenSearch with them). The "trust" store needs no seeding.
#
# Usage: scripts/seed-secrets.sh <backend> [options]
#
# Backends:
#   vault     [--mount secret]          HashiCorp Vault / OpenBao (vault or bao CLI, VAULT_ADDR + token set)
#   openbao   [--context CONTEXT]       a k3d example's dev OpenBao (k3d-multi: one per cluster, pick
#                                       it with --context). Rarely needed: each pod seeds itself
#                                       (clusters/k3d-*/k3d/openbao/values.yaml); use to rotate dev
#                                       values.
#   list                                print the keys, write nothing
# Any other store: write the keys `list` prints with your own tooling, each as
# {"value": "<secret>"}.
# Options:
#   --force     overwrite keys that already exist (default: only create missing keys)
#   --dry-run   print the keys that would be written, without values
#
# Values: random for backstage-backend-secret and opensearch-password. The OAuth client
# secrets MUST equal the client secrets your identity provider has; the defaults below are
# the ones the sample ThunderID bootstrap declares (flux|argocd/clusters/**/values/thunder.yaml).
# Override any value with an environment variable, e.g. BACKSTAGE_CLIENT_SECRET=... .
#
# Storage format: every key holds {"value": "<secret>"} (a KV entry with field "value" on
# Vault/OpenBao, a JSON string elsewhere), read back with `property: value`.
source "$(dirname "$0")/lib.sh"

backend="${1:-}"; shift || true
force=false; dry=false; mount="secret"; ctx=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mount) mount="$2"; shift 2 ;;
    --context) ctx=(--context "$2"); shift 2 ;;
    --force) force=true; shift ;;
    --dry-run) dry=true; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
need openssl python3

rand() { openssl rand -base64 32 | tr -d '\n'; }
# OpenSearch requires upper, lower, digit and special characters.
os_password() { printf '%sAa1!' "$(openssl rand -hex 16)"; }
json_value() { python3 -c 'import json,sys; print(json.dumps({"value": sys.argv[1]}))' "$1"; }

# key|value
contract() {
  cat <<EOF
backstage-backend-secret|${BACKSTAGE_BACKEND_SECRET:-$(rand)}
backstage-client-secret|${BACKSTAGE_CLIENT_SECRET:-backstage-portal-secret}
backstage-jenkins-api-key|${JENKINS_API_KEY:-placeholder-not-in-use}
backstage-github-actions-token|${GITHUB_ACTIONS_TOKEN:-placeholder-not-in-use}
backstage-github-oauth-client-secret|${GITHUB_OAUTH_CLIENT_SECRET:-placeholder-not-in-use}
opensearch-username|${OPENSEARCH_USERNAME:-admin}
opensearch-password|${OPENSEARCH_PASSWORD:-$(os_password)}
observer-oauth-client-secret|${OBSERVER_OAUTH_CLIENT_SECRET:-openchoreo-observer-resource-reader-client-secret}
rca-oauth-client-secret|${RCA_OAUTH_CLIENT_SECRET:-openchoreo-rca-agent-secret}
finops-agent-oauth-client-secret|${FINOPS_AGENT_OAUTH_CLIENT_SECRET:-openchoreo-finops-agent-secret}
EOF
}

case "$backend" in
  vault)
    cli=vault; command -v vault >/dev/null 2>&1 || cli=bao; need "$cli"
    exists() { "$cli" kv get -mount="$mount" "$1" >/dev/null 2>&1; }
    put() { printf '%s' "$2" | "$cli" kv put -mount="$mount" "$1" value=- >/dev/null; } ;;
  openbao)
    need kubectl
    bao() { kubectl "${ctx[@]}" -n openbao exec -i openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=root bao "$@"; }
    exists() { bao kv get "secret/$1" >/dev/null 2>&1; }
    put() { printf '%s' "$2" | bao kv put "secret/$1" value=- >/dev/null; } ;;
  list)
    exists() { return 1; }
    put() { :; }
    dry=true ;;
  ""|-h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  *) die "unknown backend: $backend" ;;
esac

log "seeding ${backend}"
while IFS='|' read -r key value; do
  [[ -n "$key" ]] || continue
  if ! $force && exists "$key"; then info "keep    $key (exists; --force to overwrite)"; continue; fi
  if $dry; then info "would write $key"; continue; fi
  put "$key" "$value"; info "wrote   $key"
done < <(contract)

cat <<'EOF'

Not written here (they appear on their own):
  openchoreo-trust-gateway-ca, openchoreo-trust-agent-ca-*   pushed by the trust relay to the "trust" store
Optional, add yourself when you enable the feature:
  openchoreo-remote-connect-signing-key   occ remote under Argo CD (argocd/planes/control-plane/install/optional)
EOF
