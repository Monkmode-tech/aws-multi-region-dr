# ADR 0003: Route 53 health-checked failover, not ARC routing controls

- Status: Accepted
- Date: 2026-10

## Context

Something has to move traffic from us-east-2 to us-east-1. The mechanism must work while us-east-2
is impaired, and it must not depend on an AWS *control-plane* API (create/update record calls),
because control planes are the parts most likely to be degraded in a large regional event.

## Options

1. **Script that edits DNS records during the incident.** Depends on the Route 53 control plane and
   on a human noticing. Rejected.
2. **Route 53 failover records with health checks.** Health checks and DNS answers are Route 53
   data-plane features (Route 53 has a 100% availability SLA for DNS queries). It is automatic, and
   it costs about $1 per month per optional feature (HTTPS, string match, 10-second interval).
3. **Route 53 Application Recovery Controller (ARC) routing controls.** Adds highly available
   on/off switches so an operator can force failover through the data plane, plus safety rules.
   It costs **$2.50/hour per cluster (about $1,800/month)**. ARC *Region switch* plans orchestrate
   multi-step regional failovers for **$70 per plan per month**.

## Decision

Option 2 for this workload. Automatic failover meets the RTO target. ARC's value is *operator
control* in large systems: forcing a failover when health checks look fine but the business
says otherwise, or failing over many applications together. That cost is not justified for one
API on a lab budget.

## Consequences

- Failover is automatic. There is no manual "big red button" through the data plane. The runbook
  gives the manual option: inject a fault so the primary health check fails (`scripts/gameday.sh --mode fault`),
  which uses only Lambda's control plane in the *impaired* region and may not work in a real event.
- Flapping is limited by the failure threshold (3), and Route 53 applies the same rules on recovery,
  so failback is automatic too. Teams that want manual failback would add ARC or a health-check
  inversion step.
- **Revisit when:** more than a few applications must fail over together, or the business wants
  human-approved failover. Then adopt ARC Region switch or routing controls.
