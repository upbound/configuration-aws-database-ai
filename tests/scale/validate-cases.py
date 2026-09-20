#!/usr/bin/env python3
"""Check that every case in cases.json expects what the documented rules imply.

The eval measures a model against these cases, so a wrong `expect` silently
scores a correct answer as a failure - or worse, scores a wrong answer as a
pass. That is not hypothetical: "scale down: all conditions" carried
FreeableMemory 800000000 against a db.t3.medium. That is 18.6% of a 4 GiB
class, not the ~74% it would be on a micro, so the case never met its own
"above 60%" condition. Its expectation said db.t3.small, the rules say noop,
and every eval run marked the model "missed" for answering correctly.

That is the same class-relative mistake the model made in production: a raw
byte count means different things on different instance classes. It caught the
author of the fixtures too.

This is deliberately an independent implementation of the rules, not a call
into the KCL - the point is to disagree when one of them is wrong.

    python3 tests/scale/validate-cases.py
"""
import json
import pathlib
import sys

NEXT = {"db.t3.micro": "db.t3.small",
        "db.t3.small": "db.t3.medium",
        "db.t3.medium": "db.t3.large"}
PREV = {"db.t3.small": "db.t3.micro",
        "db.t3.medium": "db.t3.small",
        "db.t3.large": "db.t3.medium"}


def decide(resource):
    """The rules exactly as operations/rds-intelligent-scaling-watch states them."""
    status = resource.get("status") or {}
    observed_class = status.get("observedInstanceClass") or ""
    observed_status = status.get("observedInstanceStatus") or ""
    desired_class = (resource["spec"]["parameters"]).get("instanceClass") or ""
    signals = status.get("scalingSignals") or {}

    # Convergence gates: a change in flight, an unsettled instance, or missing
    # state all mean do nothing.
    if not observed_class or not observed_status:
        return "noop"
    if observed_status != "available" or observed_class != desired_class:
        return "noop"

    cpu = signals.get("cpuPercent")
    mem = signals.get("freeableMemoryPercent")
    conn = signals.get("connectionsPercent")

    # UP is any-of, so an absent percentage cannot contribute.
    if ((cpu is not None and cpu > 80)
            or (conn is not None and conn > 80)
            or (mem is not None and mem < 15)):
        return NEXT.get(observed_class, "noop")

    # DOWN is all-of, so an absent percentage makes it unprovable, not true.
    if (None not in (cpu, conn, mem)
            and cpu < 20 and conn < 30 and mem > 60):
        return PREV.get(observed_class, "noop")

    return "noop"


def main():
    path = pathlib.Path(__file__).with_name("cases.json")
    cases = json.loads(path.read_text())
    bad = []
    for case in cases:
        implied = decide(case["resource"])
        expected = case.get("expect")
        if implied != expected:
            bad.append((case.get("note", "?"), expected, implied))

    print(f"{len(cases)} cases checked against the documented rules")
    for note, expected, implied in bad:
        print(f"  MISMATCH  {note}\n            expect={expected}  rules imply={implied}")
    if bad:
        print(f"\n{len(bad)} case(s) inconsistent. Either the expectation is wrong "
              f"or the rules changed without the cases following.")
        return 1
    print("all expectations consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
