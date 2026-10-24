#!/usr/bin/env bash
# Shared helpers: read Terraform outputs and talk to the API without being
# fooled by local DNS caching.
# shellcheck disable=SC2034  # variables are used by the scripts that source this

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="${ENV_DIR:-$ROOT/environments/demo}"
EVIDENCE_DIR="$ROOT/docs/evidence"

need() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || { echo "missing dependency: $bin" >&2; exit 2; }
  done
}

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

now_ms() { date +%s%3N; }

load_outputs() {
  need terraform jq
  local out
  out="$(terraform -chdir="$ENV_DIR" output -json)"
  API_URL="$(jq -r '.api_url.value' <<<"$out")"
  FQDN="${API_URL#https://}"
  PRIMARY_HOST="$(jq -r '.primary_api_host.value' <<<"$out")"
  DR_HOST="$(jq -r '.dr_api_host.value' <<<"$out")"
  PRIMARY_FN="$(jq -r '.primary_function_name.value' <<<"$out")"
  DR_FN="$(jq -r '.dr_function_name.value' <<<"$out")"
  TABLE="$(jq -r '.table_name.value' <<<"$out")"
  ZONE_ID="$(jq -r '.zone_id.value' <<<"$out")"
  PRIMARY_REGION="$(jq -r '.regions.value.primary' <<<"$out")"
  DR_REGION="$(jq -r '.regions.value.dr' <<<"$out")"
  DR_VAULT="$(jq -r '.backup_vaults.value.dr' <<<"$out")"
  SOURCE_BUCKET="$(jq -r '.documents_buckets.value.source' <<<"$out")"
  REPLICA_BUCKET="$(jq -r '.documents_buckets.value.replica' <<<"$out")"
  BACKUP_ROLE_ARN="$(jq -r '.backup_role_arn.value' <<<"$out")"
  DR_KMS_KEY_ARN="$(jq -r '.dr_kms_key_arn.value' <<<"$out")"
}

# One of the hosted zone's own name servers. Asking it directly shows the
# failover decision the moment Route 53 makes it (no resolver cache, no TTL).
authoritative_ns() {
  aws route53 get-hosted-zone --id "$ZONE_ID" \
    --query 'DelegationSet.NameServers[0]' --output text
}

# The IP Route 53 is handing out right now for the shared name.
current_ip() {
  dig +short +time=2 +tries=1 "@$NS" "$FQDN" A | grep -E '^[0-9.]+$' | head -n1 || true
}

# curl the shared name, pinned to the IP Route 53 currently returns.
# Prints "<http_status> <served_region>".
shared_request() {
  local method="$1" path="$2" data="${3:-}" ip hdrs status region
  ip="$(current_ip)"
  [ -n "$ip" ] || { echo "000 none"; return 0; }
  hdrs="$(mktemp)"
  local args=(-s -o /dev/null -D "$hdrs" -w '%{http_code}' --max-time 5
    --resolve "$FQDN:443:$ip" -X "$method" "https://$FQDN$path")
  if [ -n "$data" ]; then
    args+=(-H 'content-type: application/json' --data "$data")
  fi
  status="$(curl "${args[@]}" || echo 000)"
  region="$(grep -i '^x-served-by-region:' "$hdrs" | awk '{print $2}' | tr -d '\r' || true)"
  rm -f "$hdrs"
  echo "$status ${region:-none}"
}

regional_health() {
  curl -s --max-time 5 "https://$1/health"
}
