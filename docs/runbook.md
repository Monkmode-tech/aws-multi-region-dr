# Runbook

## Prerequisites

- AWS CLI v2 signed in with SSO (`aws sso login --profile <p>; export AWS_PROFILE=<p>`). Never use
  access keys in files.
- Terraform >= 1.10, `jq`, `curl`, `dig` (package `dnsutils` / `bind-utils`).
- A domain whose public hosted zone is in this account (Route 53 → Registered domains creates one).
- The shared state bucket from
  [`aws-secure-three-tier-platform/bootstrap`](https://github.com/Monkmode-tech/aws-secure-three-tier-platform/tree/main/bootstrap).

Pre-flight quota check. Lambda concurrency is per region, and the DR region must handle the full load:

```bash
for r in us-east-2 us-east-1; do
  echo "$r: $(aws lambda get-account-settings --region $r --query AccountLimit.ConcurrentExecutions)"
done
```

If either shows `10`, leave `lambda_reserved_concurrency = -1` and request an increase through
Service Quotas before relying on the DR region under real load.

## Deploy

```bash
cd environments/demo
cp backend.hcl.example backend.hcl            # fill in your account ID
cp terraform.tfvars.example terraform.tfvars  # domain, email
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
```

The first apply takes about 5 minutes (ACM validation and the global-table replica). Confirm the SNS
subscription emails, one per region.

## Verify

```bash
make smoke
```

All checks should report `PASS`, including the measured replication lag (typically < 1,000 ms) and
S3 replication `COMPLETED`.

## Game day (planned failover test)

```bash
make gameday          # regional outage: primary Lambda concurrency -> 0
make gameday-fault    # health-check-only fault: FAULT_MODE=fail on the primary
```

What to watch while it runs (screenshots for `docs/evidence/`):

1. Route 53 → Health checks: primary turns **Unhealthy**.
2. CloudWatch (us-east-1) → Alarms: `ledger-dr-primary-unhealthy` goes to **In alarm**. You get an email.
3. The terminal: failover observed, then failback.
4. `docs/evidence/gameday-<timestamp>.md`: RTO, RPO and the full write log.

The script always restores the primary on exit, including Ctrl-C. If it is killed hard, restore
by hand:

```bash
aws lambda delete-function-concurrency --function-name ledger-dr-api-us-east-2 --region us-east-2
# or, for fault mode, re-apply Terraform to reset the environment variables:
terraform -chdir=environments/demo apply
```

## Real incident: primary region impaired

1. **Do nothing to DNS.** Failover is automatic. Confirm it: the primary health check is unhealthy,
   and `curl -sI https://ledger.<domain>/health | grep x-served-by-region` shows `us-east-1`.
2. Check the DR region has headroom: Lambda `Throttles` and API Gateway `5xx` metrics in us-east-1.
3. Communicate: status page, stakeholders. Note the time for the post-incident review.
4. When AWS reports the primary healthy, failback is automatic once its health check passes 3 times.
   Check `GET /items` shows recent entries written in both regions.

If the primary is *partly* broken but its health check still passes (for example, wrong data
from a bad deploy), force failover with `scripts/gameday.sh --mode fault`, or roll the deploy back.

## Data recovery

**Accidental deletes or corruption (any second in the last 35 days): point-in-time restore**

```bash
aws dynamodb restore-table-to-point-in-time --region us-east-2 \
  --source-table-name ledger-dr-items --target-table-name ledger-dr-items-pitr \
  --restore-date-time 2026-10-24T14:05:00Z
```

Restores always go to a **new** table. Copy the good items back, or repoint the API after review.

**Restore drill from the cross-region backup copy (monthly):**

```bash
make restore-drill    # newest DR-vault copy -> scratch table -> count -> delete
```

The first daily backup runs at 05:00 UTC, and the copy lands in the DR vault shortly after.

## Teardown

```bash
# 1. Allow the table to be deleted
echo 'deletion_protection = false' >> environments/demo/terraform.tfvars
terraform -chdir=environments/demo apply
# 2. Destroy (vaults are force-destroyed; recovery points under Vault Lock may block deletion
#    of the DR vault until they reach the 7-day minimum - delete those after expiry)
terraform -chdir=environments/demo destroy
```
