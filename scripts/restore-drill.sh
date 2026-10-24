#!/usr/bin/env bash
#
# Restore drill: prove the cross-region backup copies actually restore.
# Takes the newest recovery point in the DR vault, restores it to a NEW
# table in the DR region, counts its items, then deletes the restored table.
#
# Usage: scripts/restore-drill.sh [--keep]

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need aws jq
load_outputs

KEEP=false
[ "${1:-}" = "--keep" ] && KEEP=true
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TARGET="${TABLE}-restore-${STAMP,,}"

log "finding newest recovery point in $DR_VAULT ($DR_REGION)"
# shellcheck disable=SC2016  # backticks are a JMESPath literal, not shell
RP_ARN="$(aws backup list-recovery-points-by-backup-vault --backup-vault-name "$DR_VAULT" \
  --region "$DR_REGION" --by-resource-type DynamoDB \
  --query 'reverse(sort_by(RecoveryPoints[?Status==`COMPLETED`], &CreationDate))[0].RecoveryPointArn' \
  --output text)"
if [ -z "$RP_ARN" ] || [ "$RP_ARN" = None ]; then
  log "no completed DynamoDB recovery point in the DR vault yet (the first daily backup + copy must finish)"
  exit 1
fi
log "recovery point: $RP_ARN"

METADATA="$(jq -cn --arg t "$TARGET" --arg k "$DR_KMS_KEY_ARN" \
  '{targetTableName: $t, encryptionType: "KMS", kmsMasterKeyArn: $k}')"

START="$(date +%s)"
JOB_ID="$(aws backup start-restore-job --region "$DR_REGION" --recovery-point-arn "$RP_ARN" \
  --iam-role-arn "$BACKUP_ROLE_ARN" --resource-type DynamoDB --metadata "$METADATA" \
  --query RestoreJobId --output text)"
log "restore job $JOB_ID -> table $TARGET"

status="RUNNING"
while [ "$status" = RUNNING ] || [ "$status" = PENDING ] || [ "$status" = CREATED ]; do
  sleep 20
  status="$(aws backup describe-restore-job --restore-job-id "$JOB_ID" --region "$DR_REGION" \
    --query Status --output text)"
  log "restore status: $status"
done
ELAPSED=$(( $(date +%s) - START ))
[ "$status" = COMPLETED ] || { log "restore failed: $status"; exit 1; }

aws dynamodb wait table-exists --table-name "$TARGET" --region "$DR_REGION"
COUNT="$(aws dynamodb scan --table-name "$TARGET" --region "$DR_REGION" --select COUNT \
  --query Count --output text)"

REPORT="$EVIDENCE_DIR/restore-drill-$STAMP.md"
mkdir -p "$EVIDENCE_DIR"
cat >"$REPORT" <<MD
# Restore drill - $STAMP

| | |
|---|---|
| Source | Cross-region copy in vault \`$DR_VAULT\` ($DR_REGION) |
| Recovery point | \`$RP_ARN\` |
| Restored to | \`$TARGET\` (KMS: regional key) |
| Restore duration | ${ELAPSED} s |
| Items in restored table | $COUNT |
| Result | $status |
MD
log "report written: ${REPORT#"$ROOT"/}"

if [ "$KEEP" = false ]; then
  log "deleting restored table $TARGET"
  aws dynamodb delete-table --table-name "$TARGET" --region "$DR_REGION" >/dev/null
fi
echo "restore: $status in ${ELAPSED}s, $COUNT items"
