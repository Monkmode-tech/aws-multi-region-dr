#!/usr/bin/env bash
#
# Game day: take the primary region's API down, measure how long until
# traffic is served from the DR region (RTO) and whether any acknowledged
# write was lost (RPO), then fail back. Writes a Markdown report to
# docs/evidence/.
#
# Usage: scripts/gameday.sh [--mode throttle|fault] [--dr-seconds 60]
#
#   throttle (default) - set the primary Lambda's concurrency to 0, so every
#                        request in that region fails: a regional compute outage.
#   fault              - set FAULT_MODE=fail so only /health reports 503: tests
#                        the health-check path without breaking writes.
#
# Measurement method: every second a writer POSTs {"seq": n} to the shared
# name, pinned (curl --resolve) to the IP that Route 53's own authoritative
# name server returns at that instant - so local DNS caching cannot hide or
# delay the failover. Every 201 response is an acknowledged write; after the
# test each acknowledged item is looked up in the DR replica.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need aws curl jq dig

MODE="throttle"
DR_SECONDS=60
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --dr-seconds) DR_SECONDS="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$MODE" in throttle|fault) ;; *) echo "--mode must be throttle or fault" >&2; exit 2 ;; esac

load_outputs
NS="$(authoritative_ns)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d)"
WRITES="$WORK/writes.log"   # epoch_ms seq http_status region item_id
REPORT="$EVIDENCE_DIR/gameday-$STAMP.md"
mkdir -p "$EVIDENCE_DIR"

#------------------------------------------------------------------------------
# Fault injection / restoration
#------------------------------------------------------------------------------
ORIGINAL_CONCURRENCY=""
ORIGINAL_ENV=""

inject() {
  if [ "$MODE" = throttle ]; then
    ORIGINAL_CONCURRENCY="$(aws lambda get-function-concurrency --function-name "$PRIMARY_FN" \
      --region "$PRIMARY_REGION" --query ReservedConcurrentExecutions --output text)"
    aws lambda put-function-concurrency --function-name "$PRIMARY_FN" --region "$PRIMARY_REGION" \
      --reserved-concurrent-executions 0 >/dev/null
  else
    ORIGINAL_ENV="$(aws lambda get-function-configuration --function-name "$PRIMARY_FN" \
      --region "$PRIMARY_REGION" --query 'Environment.Variables' --output json)"
    aws lambda update-function-configuration --function-name "$PRIMARY_FN" --region "$PRIMARY_REGION" \
      --environment "$(jq -c '{Variables: (. + {FAULT_MODE: "fail"})}' <<<"$ORIGINAL_ENV")" >/dev/null
  fi
}

restore() {
  if [ "$MODE" = throttle ] && [ -n "$ORIGINAL_CONCURRENCY" ]; then
    if [ "$ORIGINAL_CONCURRENCY" = None ]; then
      aws lambda delete-function-concurrency --function-name "$PRIMARY_FN" --region "$PRIMARY_REGION"
    else
      aws lambda put-function-concurrency --function-name "$PRIMARY_FN" --region "$PRIMARY_REGION" \
        --reserved-concurrent-executions "$ORIGINAL_CONCURRENCY" >/dev/null
    fi
    ORIGINAL_CONCURRENCY=""
  elif [ "$MODE" = fault ] && [ -n "$ORIGINAL_ENV" ]; then
    aws lambda update-function-configuration --function-name "$PRIMARY_FN" --region "$PRIMARY_REGION" \
      --environment "$(jq -c '{Variables: .}' <<<"$ORIGINAL_ENV")" >/dev/null
    ORIGINAL_ENV=""
  fi
}

WRITER_PID=""
cleanup() {
  if [ -n "$WRITER_PID" ]; then kill "$WRITER_PID" 2>/dev/null || true; fi
  restore
  rm -rf "$WORK"
}
trap cleanup EXIT

#------------------------------------------------------------------------------
# Writer: one write per second through the shared name
#------------------------------------------------------------------------------
writer() {
  local seq=0 ip body status region id
  while true; do
    seq=$((seq + 1))
    ip="$(current_ip)"
    body="$(curl -s --max-time 4 -w '\n%{http_code}' --resolve "$FQDN:443:${ip:-127.0.0.1}" \
      -H 'content-type: application/json' --data "{\"note\":\"gameday $STAMP\",\"seq\":$seq}" \
      "https://$FQDN/items" || printf '\n000')"
    status="$(tail -n1 <<<"$body")"
    region="$(head -n1 <<<"$body" | jq -r '.written_region // "none"' 2>/dev/null || echo none)"
    id="$(head -n1 <<<"$body" | jq -r '.id // "-"' 2>/dev/null || echo -)"
    echo "$(now_ms) $seq $status $region $id" >>"$WRITES"
    sleep 1
  done
}

wait_for_region() { # wait_for_region <region> <timeout_s> <since_epoch_ms>; prints ms since then
  local want="$1" timeout="$2" start="$3" served
  while [ $(( ($(now_ms) - start) / 1000 )) -lt "$timeout" ]; do
    served="$(shared_request GET /health | cut -d' ' -f2)"
    if [ "$served" = "$want" ]; then
      echo $(( $(now_ms) - start ))
      return 0
    fi
    sleep 1
  done
  echo "timeout"
  return 1
}

#------------------------------------------------------------------------------
# Run
#------------------------------------------------------------------------------
log "preflight: shared name must be served by $PRIMARY_REGION"
[ "$(shared_request GET /health | cut -d' ' -f2)" = "$PRIMARY_REGION" ] \
  || { log "primary is not serving - fix that before a game day"; exit 1; }

log "starting writer (1 write/s through $FQDN)"
writer &
WRITER_PID=$!
sleep 15

log "INJECTING FAULT in $PRIMARY_REGION (mode: $MODE)"
T_INJECT="$(now_ms)"
inject

log "waiting for Route 53 to fail over to $DR_REGION"
RTO_MS="$(wait_for_region "$DR_REGION" 300 "$T_INJECT" || true)"
log "failover observed after ${RTO_MS} ms"

log "running on DR for ${DR_SECONDS}s"
sleep "$DR_SECONDS"

log "RESTORING $PRIMARY_REGION"
T_RESTORE="$(now_ms)"
restore
FAILBACK_MS="$(wait_for_region "$PRIMARY_REGION" 300 "$T_RESTORE" || true)"
log "failback observed after ${FAILBACK_MS} ms"
sleep 10
kill "$WRITER_PID" 2>/dev/null || true
WRITER_PID=""

#------------------------------------------------------------------------------
# RPO: is every acknowledged write present in the DR replica?
#------------------------------------------------------------------------------
log "checking every acknowledged write against the $DR_REGION replica"
sleep 5   # allow in-flight replication to land before judging
total=0; acked=0; lost=0; failed=0
while read -r _ seq status region id; do
  total=$((total + 1))
  if [ "$status" = 201 ]; then
    acked=$((acked + 1))
    found="$(aws dynamodb get-item --table-name "$TABLE" --region "$DR_REGION" \
      --key "{\"id\":{\"S\":\"$id\"}}" --query 'Item.seq.N' --output text)"
    if [ "$found" != "$seq" ]; then
      lost=$((lost + 1))
      log "LOST: seq $seq ($id, written in $region)"
    fi
  else
    failed=$((failed + 1))
  fi
done <"$WRITES"

primary_writes="$(awk -v r="$PRIMARY_REGION" '$3==201 && $4==r' "$WRITES" | wc -l | tr -d ' ')"
dr_writes="$(awk -v r="$DR_REGION" '$3==201 && $4==r' "$WRITES" | wc -l | tr -d ' ')"
first_fail="$(awk -v t="$T_INJECT" '$1>=t && $3!=201 {print $1; exit}' "$WRITES")"
first_dr="$(awk -v t="$T_INJECT" -v r="$DR_REGION" '$1>=t && $3==201 && $4==r {print $1; exit}' "$WRITES")"
write_outage_ms="n/a"
if [ -n "$first_fail" ] && [ -n "$first_dr" ]; then write_outage_ms=$((first_dr - first_fail)); fi

cat >"$REPORT" <<MD
# Game day report - $STAMP

| | |
|---|---|
| Scenario | Primary region ($PRIMARY_REGION) API taken down, mode \`$MODE\` |
| Failover target | $DR_REGION |
| Measured at | Route 53 authoritative name server \`$NS\` (no client DNS cache) |

## Results

| Measure | Result | Target |
|---|---|---|
| **RTO** - fault injected until DR serves traffic | **${RTO_MS} ms** | < 120 000 ms |
| Write outage seen by clients (first failed write to first DR write) | ${write_outage_ms} ms | - |
| **RPO** - acknowledged writes lost | **${lost} of ${acked}** | 0 |
| Failback - primary restored until it serves again | ${FAILBACK_MS} ms | - |
| Writes attempted / acknowledged / failed during cutover | ${total} / ${acked} / ${failed} | - |
| Acknowledged in $PRIMARY_REGION / in $DR_REGION | ${primary_writes} / ${dr_writes} | - |

Failed writes during cutover were never acknowledged, so a client retry
would succeed against the DR region; they are availability impact, not data loss.

Fault injected at epoch ms $T_INJECT; primary restored at epoch ms $T_RESTORE.

## Write log (epoch_ms seq status region id)

\`\`\`
$(cat "$WRITES")
\`\`\`
MD

log "report written: ${REPORT#"$ROOT"/}"
echo "RTO=${RTO_MS}ms  RPO=${lost}/${acked} lost  failback=${FAILBACK_MS}ms"
[ "$lost" -eq 0 ]
