# Evidence

Scripts write their reports here automatically (`gameday-*.md`, `restore-drill-*.md`). Add
screenshots with these names, then copy the headline numbers into the Results table in the
top-level README.

| # | File | What it proves |
|---|---|---|
| 1 | `01-terraform-apply.png` | Both regions deployed from one root module |
| 2 | `02-smoke-test.png` | `make smoke` all PASS, with replication lag in ms |
| 3 | `03-health-checks-healthy.png` | Route 53 → Health checks, both Healthy |
| 4 | `04-dynamodb-global-table.png` | DynamoDB → table → Global tables tab: replicas in us-east-2 + us-east-1 |
| 5 | `05-gameday-terminal.png` | Game day output: RTO, RPO, failback |
| 6 | `06-health-check-unhealthy.png` | Primary health check Unhealthy during the game day |
| 7 | `07-alarm-email.png` | "primary-unhealthy" alarm email (redact your address) |
| 8 | `08-items-both-regions.png` | `GET /items` showing `written_region` values from both regions |
| 9 | `09-backup-copy-dr-vault.png` | AWS Backup → DR vault holding a cross-region copy |
| 10 | `10-restore-drill.png` | `make restore-drill` COMPLETED with item count |
| 11 | `11-s3-replication.png` | S3 object → Replication status COMPLETED |
| 12 | `12-cost-explorer.png` | Cost Explorer, project tag, a full month |

Before committing a screenshot, redact account IDs, emails and anything that looks like a key.
