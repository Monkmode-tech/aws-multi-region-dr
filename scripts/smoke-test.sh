#!/usr/bin/env bash
# Smoke test: both regions healthy, the shared name answers from the primary,
# and a write in the primary region shows up in the DR replica (measures
# DynamoDB global-table replication lag end to end).

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need aws curl jq dig
load_outputs
NS="$(authoritative_ns)"

fail=0
result() { # result <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected '$2', got '$3')"; fail=1; fi
}

result "primary region /health ($PRIMARY_REGION)" ok "$(regional_health "$PRIMARY_HOST" | jq -r .status)"
result "DR region /health ($DR_REGION)" ok "$(regional_health "$DR_HOST" | jq -r .status)"
result "shared name $FQDN served by" "$PRIMARY_REGION" "$(shared_request GET /health | cut -d' ' -f2)"
result "TLS + public DNS for $FQDN" 200 \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://$FQDN/health" || echo 000)"

# Replication lag: write directly to the primary, poll the DR replica.
start="$(now_ms)"
id="$(curl -s --max-time 5 -H 'content-type: application/json' \
  --data '{"note":"smoke-test replication probe"}' "https://$PRIMARY_HOST/items" | jq -r .id)"
lag="timeout"
for _ in $(seq 1 100); do
  if curl -s --max-time 3 "https://$DR_HOST/items/$id" | jq -e '.id' >/dev/null 2>&1; then
    lag="$(( $(now_ms) - start ))"
    break
  fi
  sleep 0.1
done
result "write in $PRIMARY_REGION visible in $DR_REGION (lag ${lag} ms)" yes \
  "$([ "$lag" != timeout ] && echo yes || echo no)"

# S3 cross-region replication of a small object.
probe="smoke/probe-$(date +%s).txt"
echo "replication probe" | aws s3 cp - "s3://$SOURCE_BUCKET/$probe" --region "$PRIMARY_REGION" >/dev/null
status="PENDING"
for _ in $(seq 1 60); do
  status="$(aws s3api head-object --bucket "$SOURCE_BUCKET" --key "$probe" --region "$PRIMARY_REGION" \
    --query ReplicationStatus --output text 2>/dev/null || echo PENDING)"
  [ "$status" = COMPLETED ] && break
  sleep 5
done
result "S3 object replicated to $REPLICA_BUCKET" COMPLETED "$status"

exit "$fail"
