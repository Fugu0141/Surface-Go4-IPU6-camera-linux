#!/usr/bin/env python3
"""Compare sanitized Windows and Linux camera diagnostics.

The matcher is deliberately conservative. It reports the evidence it found and
never treats a heuristic name match as a confirmed hardware mapping.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable


MAX_TEXT_FILE_BYTES = 8 * 1024 * 1024
TEXT_SUFFIXES = {
    "", ".txt", ".log", ".json", ".csv", ".xml", ".inf", ".reg",
    ".md", ".yaml", ".yml", ".conf", ".ini",
}


@dataclass(frozen=True)
class Component:
    name: str
    aliases: tuple[str, ...]
    acpi_ids: tuple[str, ...] = ()
    linux_drivers: tuple[str, ...] = ()


COMPONENTS = (
    Component("OV8865", ("ov8865", "rear camera", "back camera", "camr"),
              ("INT347A",), ("ov8865",)),
    Component("OV5693", ("ov5693", "front camera", "camf"),
              ("INT33BE",), ("ov5693",)),
    Component("Intel IPU6", ("ipu6", "intel ipu", "imaging controller"),
              (), ("intel_ipu6", "intel-ipu6")),
    Component("CSI receiver", ("csi", "csi2", "csi-2", "isys"),
              (), ("intel_ipu6_isys", "intel-ipu6-isys")),
    Component("VCM / lens", ("dw9714", "dw9719", "ad5820", "lc898", "vcm", "lens actuator"),
              (), ("dw9714", "dw9719", "ad5820")),
)

ACPI_ID_RE = re.compile(r"(?<![A-Z0-9_])(?:ACPI[\\/])?([A-Z]{3,8}[0-9A-F]{2,8})(?![A-Z0-9_])", re.I)
I2C_RE = re.compile(r"\b(?:i2c[-_:])?(\d+[-:]00[0-9a-f]{2})\b", re.I)
DRIVER_RE = re.compile(r"(?:DRIVER|driver|Kernel driver in use)\s*[:=]\s*([^\s,;]+)", re.I)


@dataclass
class Evidence:
    path: str
    line: str


@dataclass
class Match:
    component: str
    confidence: str
    rationale: str
    windows_evidence: list[Evidence]
    linux_evidence: list[Evidence]
    windows_ids: list[str]
    linux_ids: list[str]
    linux_drivers: list[str]


def iter_text(root: Path) -> Iterable[tuple[Path, str]]:
    if not root.is_dir():
        raise ValueError(f"not a directory: {root}")

    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        try:
            if path.stat().st_size > MAX_TEXT_FILE_BYTES:
                continue
            yield path, path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue


def compact_line(line: str, limit: int = 220) -> str:
    value = " ".join(line.strip().split())
    return value if len(value) <= limit else value[: limit - 1] + "…"


def find_evidence(files: list[tuple[Path, str]], root: Path,
                  terms: tuple[str, ...], limit: int = 5) -> list[Evidence]:
    lowered = tuple(term.casefold() for term in terms)
    result: list[Evidence] = []
    seen: set[tuple[str, str]] = set()
    for path, text in files:
        for line in text.splitlines():
            folded = line.casefold()
            if not any(term in folded for term in lowered):
                continue
            item = (path.relative_to(root).as_posix(), compact_line(line))
            if item in seen:
                continue
            seen.add(item)
            result.append(Evidence(*item))
            if len(result) >= limit:
                return result
    return result


def extract(pattern: re.Pattern[str], evidence: list[Evidence]) -> list[str]:
    values: set[str] = set()
    for item in evidence:
        for match in pattern.finditer(item.line):
            values.add(match.group(1).upper())
    return sorted(values)


def compare_component(component: Component,
                      windows_files: list[tuple[Path, str]], windows_root: Path,
                      linux_files: list[tuple[Path, str]], linux_root: Path) -> Match:
    terms = component.aliases + component.acpi_ids + component.linux_drivers
    win = find_evidence(windows_files, windows_root, terms)
    lin = find_evidence(linux_files, linux_root, terms)
    win_ids = extract(ACPI_ID_RE, win)
    lin_ids = extract(ACPI_ID_RE, lin)
    drivers = extract(DRIVER_RE, lin)

    exact_ids = set(win_ids) & set(lin_ids)
    expected_ids = {value.upper() for value in component.acpi_ids}
    expected_on_both = bool(expected_ids & set(win_ids) and expected_ids & set(lin_ids))
    driver_seen = any(
        driver.casefold() in "\n".join(item.line for item in lin).casefold()
        for driver in component.linux_drivers
    )

    if win and lin and (exact_ids or expected_on_both):
        confidence = "HIGH"
        rationale = "The same exact ACPI/HW identifier occurs in both dumps."
    elif win and lin and driver_seen:
        confidence = "MEDIUM"
        rationale = "Component aliases occur on both sides and a plausible Linux driver is present."
    elif win and lin:
        confidence = "MEDIUM"
        rationale = "Names occur on both sides, but no exact cross-platform ID was recovered."
    elif win or lin:
        confidence = "LOW"
        rationale = "Evidence exists on only one side; the mapping cannot be verified."
    else:
        confidence = "LOW"
        rationale = "No evidence was found in either dump."

    return Match(component.name, confidence, rationale, win, lin,
                 win_ids, lin_ids, drivers)


def one_line_evidence(items: list[Evidence]) -> str:
    if not items:
        return "Not found"
    first = items[0]
    suffix = f" (+{len(items) - 1} more)" if len(items) > 1 else ""
    return f"`{first.path}`: {first.line}{suffix}"


def escape_cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def render_markdown(matches: list[Match], windows_root: Path, linux_root: Path) -> str:
    lines = [
        "# Windows / Linux camera dump comparison",
        "",
        f"- Windows dump: `{windows_root}`",
        f"- Linux dump: `{linux_root}`",
        "- Method: exact ID matching first, then conservative name/driver heuristics.",
        "- Confidence is mapping confidence, not proof that the component works.",
        "",
        "| Component | Windows evidence | Linux evidence | Confidence | Rationale |",
        "| --- | --- | --- | --- | --- |",
    ]
    for item in matches:
        lines.append(
            "| " + " | ".join((
                escape_cell(item.component),
                escape_cell(one_line_evidence(item.windows_evidence)),
                escape_cell(one_line_evidence(item.linux_evidence)),
                item.confidence,
                escape_cell(item.rationale),
            )) + " |"
        )

    lines.extend(["", "## Detailed evidence", ""])
    for item in matches:
        lines.extend([f"### {item.component} — {item.confidence}", "", item.rationale, ""])
        for label, evidence in (("Windows", item.windows_evidence), ("Linux", item.linux_evidence)):
            lines.append(f"{label}:")
            lines.append("")
            if evidence:
                lines.extend(f"- `{ev.path}` — {ev.line}" for ev in evidence)
            else:
                lines.append("- Not found.")
            lines.append("")
        if item.component == "VCM / lens":
            lines.append("A name/binding match does not prove that a `/dev/v4l-subdev*` node, media ancillary link, or libcamera AF path exists.")
            lines.append("")

    lines.extend([
        "## Limits",
        "",
        "The script does not infer register values, lane routing, VCM type, or power sequencing when those values are absent. "
        "Review ACPI `SSDB`/`_DSD`, media topology, driver logs, and I2C traces manually before changing a driver.",
        "",
    ])
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("windows_dump", type=Path)
    parser.add_argument("linux_dump", type=Path)
    parser.add_argument("-o", "--output", type=Path, help="Markdown output (stdout if omitted)")
    parser.add_argument("--json", dest="json_output", type=Path, help="Optional machine-readable output")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        windows_files = list(iter_text(args.windows_dump))
        linux_files = list(iter_text(args.linux_dump))
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    matches = [
        compare_component(component, windows_files, args.windows_dump,
                          linux_files, args.linux_dump)
        for component in COMPONENTS
    ]
    report = render_markdown(matches, args.windows_dump, args.linux_dump)

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report, encoding="utf-8")
    else:
        print(report)

    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(
            json.dumps([asdict(item) for item in matches], indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
