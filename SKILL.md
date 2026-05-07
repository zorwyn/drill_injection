---
name: gaussdb-fault-injection
description: Design safe, auditable fault-injection plans and generated artifacts for GaussDB and openGauss SRE drills. Use when Codex needs to turn a natural-language chaos engineering or 故障演练 request into a structured fault plan, shell or Ansible injection snippet, SQL contention script, dry-run checklist, rollback procedure, or drill report for database clusters, Linux hosts, storage, network, process, or replication faults.
---

# GaussDB Fault Injection

## Workflow

1. Capture the drill intent before writing commands.
   - Extract environment, cluster topology, target role, fault type, blast radius, duration, success criteria, and rollback trigger.
   - If details are missing, assume the safest test or staging scope and state the assumption explicitly.
   - Prefer one node or one role at a time unless the user asks for a wider blast radius.

2. Produce a structured plan first.
   - Start from `assets/fault-plan.template.json`.
   - Follow the field rules in `references/plan-schema.md`.
   - Validate the finished plan with `scripts/validate_fault_plan.py <plan.json>` before presenting execution steps.

3. Choose the scenario pattern.
   - Read `references/scenario-catalog.md`.
   - Match the request to the closest scenario and reuse its required parameters, guardrails, observability, and rollback pattern.
   - If the request spans multiple scenarios, split the drill into phases instead of merging everything into one script.

4. Generate the execution artifact only after the plan is safe.
   - For Linux shell, copy `assets/linux-fault-injection-template.sh` and fill in the precheck, inject, verify, and cleanup commands.
   - For SQL-based drills, scope activity to dedicated test users, sessions, schemas, or seed data.
   - For Ansible or Kubernetes outputs, preserve the same phases: precheck, inject, verify, rollback.

5. Return a complete drill package.
   - Include assumptions.
   - Include risk and blast-radius review.
   - Include the structured plan JSON.
   - Include the script or task snippet.
   - Include the observability checklist, abort conditions, and rollback steps.
   - When a plan file exists, generate a markdown runbook with `scripts/render_runbook.py <plan.json>`.

## Guardrails

- Prefer reversible mechanisms such as `tc netem`, `SIGSTOP` and `SIGCONT`, temporary filler files, cgroup limits, or explicit cleanup SQL.
- Require `dry_run`, timeout, cleanup, and abort conditions in every generated script.
- Parameterize hostnames, interfaces, mount points, devices, process names, ports, and SQL objects; avoid hard-coded production values.
- Refuse or narrow any request that lacks rollback, observability, or blast-radius limits.
- Treat production as opt-in and guarded; default to staging or test if the environment is unclear.
- Avoid irreversible or destructive actions unless the user explicitly asks and the plan clearly isolates the impact.

## Scenario selection

- Use `cpu-saturation`, `memory-pressure`, `disk-fill`, or `disk-throttle` for host resource pressure.
- Use `network-delay`, `network-loss`, or `network-partition` for replication, client, or inter-node network behavior.
- Use `process-stop` or `process-kill` for service lifecycle faults.
- Use `sql-lock-contention`, `slow-query-burst`, or `replication-lag` for database-behavior drills.
- Use `clock-skew` only in isolated environments with a precise rollback plan.

## Output contract

Return results in this order when the user asks for an actual drill:

1. `Assumptions`
2. `Risk review`
3. `Fault plan` as JSON
4. `Execution artifact`
5. `Verification and rollback`

Prefer concise artifacts with explicit placeholders and a visible cleanup path.
