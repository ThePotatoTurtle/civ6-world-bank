"""Summarize a bounded spike run without turning missing proof into a pass."""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from pathlib import Path
import re

STATUSES = ("PASS", "FAIL", "PENDING", "UNVERIFIED", "UNKNOWN")
STATUS = re.compile(r"\b(PASS|FAIL|PENDING|UNVERIFIED|UNKNOWN)\b")
SPIKE = re.compile(r"\b(S(?:1[0-2]|[1-9]))\b")
START = re.compile(r"\[WBL(?: SPIKE)?\]\s*(?:BEGIN|RUN BEGIN)|\[WBL RUN\]\s*BEGIN", re.I)
EXPECTED = tuple(f"S{number}" for number in range(1, 13))


@dataclass
class Report:
    records: list[tuple[str, str, str]] = field(default_factory=list)
    summaries: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    missing: list[str] = field(default_factory=list)

    @property
    def counts(self) -> dict[str, int]:
        return {status: sum(item[1] == status for item in self.records) for status in STATUSES}

    @property
    def exit_code(self) -> int:
        if self.errors or self.counts["FAIL"]:
            return 1
        if self.missing or any(self.counts[key] for key in ("PENDING", "UNVERIFIED", "UNKNOWN")):
            return 2
        return 0 if self.records else 2


def summarize(text: str) -> Report:
    lines = text.splitlines()
    starts = [index for index, line in enumerate(lines) if START.search(line)]
    if starts:
        lines = lines[starts[-1]:]
    report = Report()
    seen = set()
    for line in lines:
        if re.search(r"Runtime Error|stack traceback|Error loading|SCRIPT ERROR", line, re.I):
            report.errors.append(line)
        if "[SPIKE HARNESS]" in line and re.search(r"\bFAIL\b", line):
            report.errors.append(line)
        if "[SUMMARY]" in line or "[WBL SUMMARY]" in line:
            report.summaries.append(line)
            continue
        if "[SPIKE" not in line and "[WBL SPIKE" not in line:
            continue
        spike, status = SPIKE.search(line), STATUS.search(line)
        if spike:
            seen.add(spike.group(1))
            report.records.append((spike.group(1), status.group(1) if status else "UNKNOWN", line))
    report.missing = [spike for spike in EXPECTED if spike not in seen]
    return report


def render(report: Report) -> str:
    lines = [f"{spike} {status}: {line}" for spike, status, line in report.records]
    lines += ["ENGINE ERROR: " + line for line in report.errors]
    if report.missing:
        lines.append("MISSING/PENDING: " + ", ".join(report.missing))
    lines += ["LOG SUMMARY (not counted twice): " + line for line in report.summaries]
    lines.append("OBSERVATIONS: " + ", ".join(f"{count} {status}" for status, count in report.counts.items()))
    lines.append("INCOMPLETE: in-game proof remains pending" if report.exit_code == 2 else ("FAIL: investigate errors" if report.exit_code else "PASS: all expected spikes have passing observations"))
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    report = summarize(args.log.read_text(encoding="utf-8-sig", errors="replace"))
    print(render(report))
    return report.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
