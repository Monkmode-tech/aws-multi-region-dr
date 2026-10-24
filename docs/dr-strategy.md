# DR strategy: why warm standby, and what it does and doesn't protect

## The four AWS disaster-recovery strategies

AWS's [Disaster Recovery of Workloads on AWS](https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/disaster-recovery-options-in-the-cloud.html)
whitepaper describes four strategies. Moving down the table, each one costs more and recovers faster:

| Strategy | What runs in the DR region | Typical RPO | Typical RTO | Relative cost |
|---|---|---|---|---|
| Backup & restore | Nothing but backups | Hours (last backup) | Hours (rebuild + restore) | $ |
| Pilot light | Data replicated; compute off or scaled to zero | Seconds-minutes | Tens of minutes (start + scale compute) | $$ |
| **Warm standby (this repo)** | **Data replicated; full stack running, scaled down** | **Seconds** | **Minutes** | **$$$** |
| Multi-site active/active | Full stack serving traffic in both | ~0 | ~0 (clients already spread) | $$$$ |

## Why warm standby fits this workload

The workload is a small "ledger" API: clients write entries and read them back.

- **The business target is RTO < 2 minutes and RPO < 5 seconds** for acknowledged writes. Backup &
  restore (hours) and pilot light (tens of minutes to start and scale compute) both miss the RTO.
- **Serverless makes warm standby almost free.** API Gateway, Lambda and on-demand DynamoDB bill
  per request. A standby region that takes no traffic costs only its health checks, keys and alarms.
  The usual warm-standby problem, paying for idle servers, doesn't arise.
- **Serverless also removes the "scale up during the disaster" step.** In a classic warm standby, the
  DR fleet runs at maybe 10% and must scale out during the event, while every other customer in
  the failed region is trying to do the same. Lambda in the DR region is already at full capacity
  (within account quotas). See [ADR 0001](adr/0001-serverless-warm-standby.md).
- **Active/active was rejected for now.** Both regions *can* accept writes (DynamoDB global tables
  are multi-active), but routing everyone to one region at a time avoids conflicting writes to the
  same item (last-writer-wins). It also keeps the failure story simple to reason about and test.
  Moving to latency-based routing is a DNS change, documented as the next step.

## Where the RTO comes from

```
fault ──► Route 53 checkers see failures ──► record flips ──► clients re-resolve ──► DR serves
          (3 failures x 10s interval)        (seconds)         (alias TTL ~60s)
          ≈ 30s                                                 0-60s
```

`scripts/gameday.sh` measures the first three stages at Route 53's own authoritative name server,
so local DNS caching can't hide the failover. A real client adds up to the record TTL on top. The
README reports both numbers once measured.

## Where the RPO comes from

DynamoDB global tables (multi-Region *eventual* consistency) replicate asynchronously, usually in
under a second. A write acknowledged in us-east-2 in the last moment before a regional failure
*could* be lost. The game day checks every acknowledged write against the DR replica. The smoke
test measures typical replication lag.

**Option for RPO = 0:** DynamoDB's multi-Region *strong* consistency (MRSC) commits each write
synchronously across Regions. It needs three Regions (or two plus a witness), adds cross-region
latency to every write, and must be set up on an empty table. For a ledger that legally cannot
lose an acknowledged entry, that trade is worth it. For this demo, eventual consistency with
measured lag is the right default. See [ADR 0002](adr/0002-dynamodb-global-tables.md).

## Replication is not backup

Replication copies *everything*, including mistakes, to the other region in under a second:

| Disaster | Protected by |
|---|---|
| Region (or the API stack in it) fails | Route 53 failover to the warm standby |
| Bad deploy in one region | Health check fails → failover; roll back the deploy |
| Someone deletes or corrupts items | DynamoDB **point-in-time recovery** (any second in the last 35 days), per replica |
| Someone deletes the table | `deletion_protection_enabled`; AWS Backup recovery points |
| Ransomware / compromised admin deletes backups | DR vault copies with **Vault Lock** (minimum retention 7 days) |
| Documents overwritten or deleted | S3 versioning (30 days of old versions) + replicated delete markers |

`scripts/restore-drill.sh` restores the newest DR-vault copy to a scratch table and counts its items.
A backup that has never been restored is only a hope.

## What is *not* covered (honest limits)

- **Global control-plane dependencies.** Failover needs the Route 53 *data plane* (health checks and
  DNS answers), which is designed for 100% availability. It does not need any control-plane API
  call during the event, which is why this design uses health-check failover rather than a
  script that edits DNS records. Route 53 ARC routing controls would add manual, data-plane override
  switches. See [ADR 0003](adr/0003-route53-failover-vs-arc.md).
- **Account-level failure** (compromised root, closed account). Out of scope; the production answer
  is backup copies in a separate, locked-down account (AWS Backup cross-account copy).
- **Client behaviour.** Clients that cache DNS beyond the TTL, or never retry a failed write, see a
  longer outage. `POST /items` is not idempotent, so a retry after a timeout can create a duplicate
  entry. A production ledger would accept a client-supplied idempotency key and use a conditional put.
