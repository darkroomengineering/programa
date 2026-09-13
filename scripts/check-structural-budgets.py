#!/usr/bin/env python3
"""Enforce reviewed line budgets for structural lifecycle owner families."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class FileBudget:
    path: str
    baseline: int
    maximum: int
    owner: str


@dataclass(frozen=True)
class FamilyBudget:
    name: str
    paths: tuple[str, ...]
    baseline: int
    maximum: int
    owner: str


FILES = (
    FileBudget("Sources/AppDelegate.swift", 11_078, 10_938, "application lifecycle entrypoint"),
    FileBudget("Sources/AppLifecycleCoordinator.swift", 0, 125, "AppLifecycleCoordinator"),
    FileBudget("Sources/AppDelegate+StartupHandoff.swift", 0, 75, "StartupSessionHandoff"),
    FileBudget("Sources/ContentView.swift", 5_949, 5_728, "command palette view adapter"),
    FileBudget("Sources/CommandPaletteController.swift", 71, 283, "CommandPaletteController"),
    FileBudget("CLI/programa.swift", 7_886, 7_584, "ProgramaCLI entrypoint"),
    FileBudget("CLI/CLICommandDispatcher.swift", 0, 257, "CLICommandDispatcher"),
    FileBudget("CLI/CLI+Hooks.swift", 4_381, 4_257, "hook provider primitives"),
    FileBudget("CLI/HookInstallationCoordinator.swift", 0, 168, "HookInstallationCoordinator"),
    FileBudget("Sources/TerminalController.swift", 3_149, 3_021, "terminal RPC adapter"),
    FileBudget(
        "Sources/TerminalController+BrowserAutomation.swift",
        6_297,
        6_153,
        "browser automation effects",
    ),
    FileBudget("Sources/BrowserRPCDispatcher.swift", 0, 247, "BrowserRPCDispatcher/BrowserRPCState"),
)

FAMILIES = (
    FamilyBudget(
        "application-and-command-palette",
        (
            "Sources/AppDelegate.swift",
            "Sources/AppLifecycleCoordinator.swift",
            "Sources/AppDelegate+StartupHandoff.swift",
            "Sources/ContentView.swift",
            "Sources/CommandPaletteController.swift",
        ),
        17_098,
        17_074,
        "AppLifecycleCoordinator + CommandPaletteController",
    ),
    FamilyBudget(
        "cli-and-hook-dispatch",
        (
            "CLI/programa.swift",
            "CLI/CLICommandDispatcher.swift",
            "CLI/CLI+Hooks.swift",
            "CLI/HookInstallationCoordinator.swift",
        ),
        12_267,
        12_266,
        "CLICommandDispatcher + HookInstallationCoordinator",
    ),
    FamilyBudget(
        "browser-rpc",
        (
            "Sources/TerminalController.swift",
            "Sources/TerminalController+BrowserAutomation.swift",
            "Sources/BrowserRPCDispatcher.swift",
        ),
        9_446,
        9_421,
        "BrowserRPCDispatcher + BrowserRPCState",
    ),
)


def line_count(path: Path) -> int:
    with path.open("rb") as source:
        return sum(1 for _ in source)


def main() -> int:
    counts: dict[str, int] = {}
    failures: list[str] = []
    for budget in FILES:
        path = ROOT / budget.path
        if not path.is_file():
            failures.append(f"missing: {budget.path} (owner: {budget.owner})")
            continue
        current = line_count(path)
        counts[budget.path] = current
        status = "PASS" if current <= budget.maximum else "FAIL"
        print(
            f"{status} file {budget.path}: current={current} max={budget.maximum} "
            f"baseline={budget.baseline} owner={budget.owner}"
        )
        if current > budget.maximum:
            failures.append(f"{budget.path} exceeds {budget.maximum} lines by {current - budget.maximum}")

    for family in FAMILIES:
        if any(path not in counts for path in family.paths):
            failures.append(f"{family.name} cannot be measured because a member is missing")
            continue
        current = sum(counts[path] for path in family.paths)
        status = "PASS" if current <= family.maximum else "FAIL"
        print(
            f"{status} family {family.name}: current={current} max={family.maximum} "
            f"baseline={family.baseline} owner={family.owner}"
        )
        if current > family.maximum:
            failures.append(f"{family.name} exceeds {family.maximum} lines by {current - family.maximum}")

    if failures:
        for failure in failures:
            print(f"error: {failure}", file=sys.stderr)
        return 1
    print("structural budgets: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
