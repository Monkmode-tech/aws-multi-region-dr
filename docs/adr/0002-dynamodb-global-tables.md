# ADR 0002: DynamoDB global tables (eventual consistency) for the data tier

- Status: Accepted
- Date: 2026-10

## Context

The data tier must survive the loss of a region with near-zero data loss. It must be writable in
the DR region immediately after failover, with no "promote the replica" step, and cost almost
nothing while idle.

## Options

| Option | Cross-region RPO | Failover step for writes | Idle cost |
|---|---|---|---|
| RDS MySQL cross-region read replica | Seconds-minutes (async) | **Promote the replica** (minutes; breaks replication; manual or scripted) | An always-on instance in each region |
| Aurora Global Database | Typically < 1 s | Managed switchover/failover (about a minute) | Always-on instances in each region |
| **DynamoDB global table, multi-Region eventual consistency (MREC)** | Typically < 1 s (async) | **None**: every replica already accepts writes | Pay per request + storage |
| DynamoDB global table, multi-Region strong consistency (MRSC) | **0**: writes commit synchronously | None | Same pricing model. Needs 3 Regions or 2 + a witness, and adds write latency |

## Decision

DynamoDB global table with MREC. Every replica accepts writes, so failover needs no database
operation. That removes the slowest and most error-prone step of most DR runbooks. The workload
is key-value (items by ID), which suits DynamoDB.

## Consequences

- RPO is "replication lag at the moment of failure" (typically under a second). This is measured by
  `scripts/smoke-test.sh` (lag) and `scripts/gameday.sh` (lost acknowledged writes), not assumed.
- Concurrent writes to the *same item* in two regions resolve last-writer-wins. Single-region
  routing (ADR 0001) avoids this in normal operation.
- Each replica uses a KMS key in its own region and has its own PITR. Backups are still required
  (see `docs/dr-strategy.md`, "Replication is not backup").
- If a future requirement demands RPO = 0, MRSC is a re-create (it must start from an empty table)
  with a third Region or a witness. That is a data migration, so it is called out here early.
