# ADR 0001: Serverless warm standby across us-east-2 and us-east-1

- Status: Accepted
- Date: 2026-10

## Context

The ledger API needs RTO < 2 minutes and RPO < 5 seconds for acknowledged writes. The budget is a
personal lab account (about $50/month shared across several projects), so the DR region cannot
cost much while idle. The coursework version (CLCS 645 Unit 4) recovered from a single-region
target deregistration. It never left its region, and its recovery was a manual script run.

## Options

1. **Backup & restore**: daily backups copied to us-east-1, rebuilt with Terraform on demand.
   Cheapest, but RTO is tens of minutes to hours and RPO is up to 24 hours. Misses both targets.
2. **Pilot light with containers/EC2**: data replicated, compute at zero in DR. Meets RPO, but
   starting and scaling compute during a regional event takes 10+ minutes and competes for capacity.
3. **Warm standby on serverless**: the identical API stack (API Gateway, Lambda, DynamoDB replica)
   deployed in both regions, with Route 53 health-checked failover.
4. **Active/active**: latency-based routing to both regions all the time.

## Decision

Option 3. Serverless compute bills per request, so the warm standby costs roughly what pilot light
would (health checks, keys, alarms) while being already "scaled up". No scale-out is needed during
the event. The DR region is us-east-1 for two extra reasons: it is far enough from us-east-2 to be
a separate failure domain, and it is where Route 53 publishes health-check metrics, so the alarms
on the failover itself live in the surviving region.

## Consequences

- Detection plus DNS cut-over is automatic (~30 s plus client TTL). No human or script needs to
  make an AWS API call during the event.
- Every change must be deployed to both regions. Terraform does this from one root module, with
  the regional stack as one module instantiated twice.
- Moving to active/active later is a routing-policy change (failover → latency), plus conflict
  handling for same-item writes.
- Lambda concurrency quotas are per region. The DR region must have the same quota as the primary.
  New accounts start low (often 10), so `docs/runbook.md` includes a pre-flight quota check.
