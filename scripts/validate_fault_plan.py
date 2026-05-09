#!/usr/bin/env python3
import json
import sys
from pathlib import Path

SUPPORTED_SCENARIOS = {
    "cpu-saturation": {"workers"},
    "memory-pressure": {"duration_min"},
    "disk-fill": {"path", "min_free_gb"},
    "disk-throttle": {"duration_min"},
    "network-delay": {"interface", "latency_ms", "jitter_ms"},
    "network-loss": {"interface", "loss_pct"},
    "network-partition": {"duration_min", "direction"},
    "process-stop": set(),
    "process-kill": {"signal", "restart_expectation"},
    "sql-lock-contention": {"database", "schema", "lock_object", "hold_sec"},
    "slow-query-burst": {"database", "concurrency", "duration_min"},
    "replication-lag": {"target_role", "mechanism", "duration_min"},
    "dead-tuple-bloat": {"database", "schema", "table", "update_rows", "txn_hold_sec"},
    "barrier-lock": {"database", "schema", "table", "backup_hold_sec"},
    "clock-skew": {"offset_sec", "time_sync_service"},
}

REQUIRED_TOP_LEVEL = [
    "version",
    "objective",
    "environment",
    "topology",
    "targets",
    "fault",
    "guards",
    "observability",
    "verification",
    "rollback",
]


def load_plan(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def validate_plan(plan: dict) -> list[str]:
    errors: list[str] = []

    for key in REQUIRED_TOP_LEVEL:
        if key not in plan:
            errors.append(f"missing top-level field: {key}")

    if errors:
        return errors

    environment = plan["environment"]
    for key in ("name", "type"):
        if not environment.get(key):
            errors.append(f"environment.{key} is required")

    topology = plan["topology"]
    if not topology.get("cluster"):
        errors.append("topology.cluster is required")
    if not isinstance(topology.get("roles"), list) or not topology["roles"]:
        errors.append("topology.roles must be a non-empty list")

    targets = plan["targets"]
    if not isinstance(targets, list) or not targets:
        errors.append("targets must be a non-empty list")
    else:
        for index, target in enumerate(targets):
            for key in ("host", "role", "scope"):
                if not target.get(key):
                    errors.append(f"targets[{index}].{key} is required")

    fault = plan["fault"]
    scenario = fault.get("scenario")
    if scenario not in SUPPORTED_SCENARIOS:
        errors.append(
            f"fault.scenario must be one of: {', '.join(sorted(SUPPORTED_SCENARIOS))}"
        )
    if not fault.get("mechanism"):
        errors.append("fault.mechanism is required")
    if not isinstance(fault.get("duration_min"), int) or fault["duration_min"] <= 0:
        errors.append("fault.duration_min must be a positive integer")
    parameters = fault.get("parameters")
    if not isinstance(parameters, dict):
        errors.append("fault.parameters must be an object")
    elif scenario in SUPPORTED_SCENARIOS:
        missing = sorted(
            key for key in SUPPORTED_SCENARIOS[scenario] if key not in parameters
        )
        if missing:
            errors.append(
                f"fault.parameters missing for {scenario}: {', '.join(missing)}"
            )

    guards = plan["guards"]
    if not isinstance(guards.get("dry_run"), bool):
        errors.append("guards.dry_run must be a boolean")
    if not isinstance(guards.get("max_nodes"), int) or guards["max_nodes"] <= 0:
        errors.append("guards.max_nodes must be a positive integer")
    abort_conditions = guards.get("abort_conditions")
    if not isinstance(abort_conditions, list) or not abort_conditions:
        errors.append("guards.abort_conditions must be a non-empty list")

    observability = plan["observability"]
    if not isinstance(observability.get("metrics"), list) or not observability["metrics"]:
        errors.append("observability.metrics must be a non-empty list")

    verification = plan["verification"]
    for key in ("prechecks", "during_checks", "success_conditions"):
        value = verification.get(key)
        if not isinstance(value, list) or not value:
            errors.append(f"verification.{key} must be a non-empty list")

    rollback = plan["rollback"]
    if rollback.get("mode") not in {"automatic", "manual"}:
        errors.append("rollback.mode must be automatic or manual")
    for key in ("steps", "success_conditions"):
        value = rollback.get(key)
        if not isinstance(value, list) or not value:
            errors.append(f"rollback.{key} must be a non-empty list")

    return errors


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate_fault_plan.py <plan.json>", file=sys.stderr)
        return 2

    plan_path = Path(sys.argv[1])
    try:
        plan = load_plan(plan_path)
    except FileNotFoundError:
        print(f"plan not found: {plan_path}", file=sys.stderr)
        return 2
    except json.JSONDecodeError as exc:
        print(f"invalid json: {exc}", file=sys.stderr)
        return 2

    errors = validate_plan(plan)
    if errors:
        print("plan validation failed:")
        for error in errors:
            print(f"- {error}")
        return 1

    print(f"plan is valid: {plan_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
