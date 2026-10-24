# Cost

Designed to be **left running** between game days. Prices are us-east-1/us-east-2 on-demand list
prices as of October 2026. Check the [AWS Pricing Calculator](https://calculator.aws/) before you rely on them.

## Always-on (both regions, idle apart from health checks)

| Item | Basis | ≈ $/month |
|---|---|---|
| Route 53 health checks | Primary: HTTPS + string match + 10 s interval (3 × $1). Secondary: HTTPS + string match (2 × $1). Base checks for AWS endpoints fall within the free 50 | 5.00 |
| Health-check traffic | 3 checker regions → roughly 1 request/s combined ≈ 2.6 M requests/month: HTTP API ($1.00/M), Lambda requests ($0.20/M; compute inside the free tier), DynamoDB reads | 3.50 |
| KMS keys | 2 customer-managed keys × $1 | 2.00 |
| CloudWatch alarms | 6 standard alarms × $0.10 | 0.60 |
| Hosted zone | $0.50, shared with the other portfolio projects | 0.50 |
| DynamoDB, S3, backups, logs | Kilobytes to megabytes of data; replicated writes and cross-region copies cost cents | < 0.50 |
| **Total** | | **≈ $12** |

## Per game day

A 3-minute game day makes about 200 writes and a few hundred reads: effectively $0. The restore
drill restores a tiny table: cents.

## What would change the bill

| Change | Effect |
|---|---|
| Real traffic: 1 M API calls/month | + ~$1.20 (HTTP API + Lambda) + DynamoDB writes in **both** regions (~$0.63/M write requests per region) |
| S3 Replication Time Control on | + $0.015/GB replicated |
| ARC routing control cluster | + ~$1,800 (see ADR 0003) |
| Third region for MRSC (RPO 0) | Roughly +50% data-tier cost, plus a third API stack if it also serves traffic |

## Cost guardrails

- The $50/month account budget alarm comes from the
  [bootstrap](https://github.com/Monkmode-tech/aws-secure-three-tier-platform/tree/main/bootstrap).
- API stage throttling (20 rps / 40 burst) caps what a scripted abuser can cost.
- Health checks use 3 checker regions (the minimum) instead of the default ~8 to cut probe traffic.
