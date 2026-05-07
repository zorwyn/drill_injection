# Fault plan schema

Use this shape for every drill plan before generating scripts.

## Required top-level fields

- `version`
- `objective`
- `environment`
- `topology`
- `targets`
- `fault`
- `guards`
- `observability`
- `verification`
- `rollback`

## JSON shape

```json
{
  "version": "1.0",
  "objective": "Describe the drill goal",
  "environment": {
    "name": "staging-1",
    "type": "staging",
    "approval": "manual",
    "window": "2026-05-07T10:00:00+08:00/2026-05-07T10:30:00+08:00"
  },
  "topology": {
    "cluster": "gaussdb-stg",
    "roles": ["cn", "dn"],
    "primary_host": "dn-01",
    "standby_hosts": ["dn-02"]
  },
  "targets": [
    {
      "host": "dn-01",
      "role": "dn",
      "scope": "tablespace-mount",
      "selector": "mount=/gaussdb/data"
    }
  ],
  "fault": {
    "scenario": "disk-fill",
    "mechanism": "fallocate",
    "duration_min": 15,
    "parameters": {
      "path": "/gaussdb_fault/drill.bin",
      "bytes": "20G",
      "min_free_gb": 20
    }
  },
  "guards": {
    "dry_run": true,
    "max_nodes": 1,
    "abort_conditions": [
      "replication lag > 30s",
      "disk free < 15G",
      "failover starts"
    ],
    "timeouts": {
      "inject_s": 900,
      "rollback_s": 120
    }
  },
  "observability": {
    "metrics": [
      "replication lag",
      "sql p95 latency",
      "disk usage",
      "iowait",
      "connection errors"
    ],
    "logs": ["gaussdb log", "kernel dmesg"],
    "alerts": ["replication-lag", "disk-usage-high"]
  },
  "verification": {
    "prechecks": [
      "verify target host role",
      "verify rollback path exists"
    ],
    "during_checks": [
      "sample metrics every 30s"
    ],
    "success_conditions": [
      "fault takes effect",
      "cluster stays reachable"
    ]
  },
  "rollback": {
    "mode": "automatic",
    "steps": [
      "delete filler file",
      "sync and recheck disk free",
      "clear injected state"
    ],
    "success_conditions": [
      "disk free returns above threshold",
      "alerts recover"
    ]
  }
}
```

## Field rules

- Set `environment.type` to `test`, `staging`, `preprod`, or `prod`.
- Keep `targets` non-empty and list each host explicitly.
- Set `fault.scenario` from the catalog in `references/scenario-catalog.md`.
- Keep `fault.parameters` scenario-specific and minimal.
- Set `guards.dry_run` to `true` until the user explicitly asks for executable output.
- Include at least one `abort_conditions` entry and at least one `rollback.steps` entry.
- Include metrics that expose both service health and blast radius.
- Keep `verification.prechecks` actionable; avoid vague items like `observe system`.
