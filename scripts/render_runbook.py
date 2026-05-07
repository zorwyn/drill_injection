#!/usr/bin/env python3
import json
import sys
from pathlib import Path


def load_plan(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def bullet_list(items: list[str]) -> str:
    return "\n".join(f"- {item}" for item in items)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: render_runbook.py <plan.json>", file=sys.stderr)
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

    environment = plan["environment"]
    topology = plan["topology"]
    fault = plan["fault"]
    target_lines = [
        f"{target['host']} ({target['role']}, {target['scope']})"
        for target in plan["targets"]
    ]

    sections = [
        "# Fault Injection Runbook",
        "",
        "## Summary",
        f"- Objective: {plan['objective']}",
        f"- Environment: {environment['name']} ({environment['type']})",
        f"- Cluster: {topology['cluster']}",
        f"- Scenario: {fault['scenario']}",
        f"- Mechanism: {fault['mechanism']}",
        f"- Duration: {fault['duration_min']} minutes",
        "",
        "## Targets",
        bullet_list(target_lines),
        "",
        "## Parameters",
        bullet_list(
            [f"{key}: {value}" for key, value in fault.get("parameters", {}).items()]
        ),
        "",
        "## Prechecks",
        bullet_list(plan["verification"]["prechecks"]),
        "",
        "## Observability",
        bullet_list(plan["observability"]["metrics"]),
        "",
        "## Abort Conditions",
        bullet_list(plan["guards"]["abort_conditions"]),
        "",
        "## During Drill",
        bullet_list(plan["verification"]["during_checks"]),
        "",
        "## Rollback",
        bullet_list(plan["rollback"]["steps"]),
        "",
        "## Success Conditions",
        bullet_list(plan["verification"]["success_conditions"]),
        "",
        "## Rollback Success Conditions",
        bullet_list(plan["rollback"]["success_conditions"]),
    ]

    print("\n".join(sections))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
