# Contextual next actions implementation plan

> **For agentic workers:** Use superpowers:executing-plans for implementation; independent test/documentation assistance and a final fresh review.

**Goal:** Let an administrator move from diagnostics to update through contextual choices without searching manual menus.
**Architecture:** A shared interactive action loop wraps existing CLI commands; structured readiness and a private result descriptor carry context, never authorize bypassing guards.
**Tech Stack:** Bash 4.2, embedded Python, Python PTY regression tests, disposable Docker containers.
**Spec:** docs/superpowers/specs/2026-11-08-contextual-actions-design.md

## Global Constraints

- Preserve manual menu numbers, existing CLI behavior and all update/rollback guards.
- Enter/0 go back; EOF exits; updates and rollback always require explicit selection.
- Readiness is not inferred from diagnostic exit code or severity.
- Selected site is revalidated; stale session data never triggers recovery of another operation.
- No production-server update or network access in automated tests.

## Review Focus

- A zero diagnostic exit code with unsupported profile must not offer update.
- A failed update before session creation must not expose rollback of an older session.
- Site descriptors containing spaces must survive navigation without eval or word splitting.
- EOF/Enter/invalid choices must never select an update or recovery action.
- Failed rollback retains the original update ID, not the rollback attempt ID.

### Task 1: Contextual menu behavior and regression tests

**Files:** install.sh; tests/test-menu.py; tests/test-next-actions.py.
**Interfaces:** menu_update_readiness sets NEXT_STATUS/NEXT_REASON/NEXT_VERSION/NEXT_TARGET;
menu_action runs an existing CLI action and loops over follow-ups; menu_record writes
allowed result records only when internal --menu-action mode is enabled on fd 3.

- [x] Add failing readiness and PTY navigation tests, including the five review cases.
- [x] Run new tests against the baseline; confirm missing behavior causes failures.
- [x] Implement readiness, result metadata and iterative follow-up actions in install.sh.
- [x] Wire existing checks/plan/site/setup/update/status/rollback menu entries without renumbering.
- [x] Run new tests, existing menu/confirmation/integration/branch tests in disposable containers.

### Task 2: Documentation and complete validation

**Files:** README.md; README.txt; tests/README.md.
**Interfaces:** document the implemented menu labels and guarantees from Task 1.

- [x] Explain the beginner path, contextual actions, safe default and preparation vs installation.
- [x] Add test instructions and coverage description.
- [x] Run Bash syntax/ShellCheck and relevant published regression suites on Bash 4.2 and Python 3.
- [x] Request independent review of the complete diff; address actionable defects with regression tests.
- [x] Report actual checks and limitations; leave the changes reviewable in the current checkout.

## Execution record

- User authorized implementation; no additional design/plan approval requested.
- Working in current clean checkout on codex/contextual-next-actions, so files remain visible to user.
- Baseline: 29 menu cases and 100 confirmation cases pass in python:3.11-slim.
- RED: initial contextual tests failed against the original installer because readiness/navigation were absent.
- Final Python-container validation: contextual actions 45/45 (including real full-script child/PTY flow), manual menu 29/29, confirmations 100/100, setup 18/18, integration 25/25, branches 59/59, site selection 6/6.
- CentOS 7 / Bash 4.2: syntax, publisher, publisher-client for both branches, environment, discovery, startup and 100 confirmation cases passed.
- ShellCheck has the same 12 existing warnings as HEAD (SC1007 x8, SC2174 x2, SC2190 x2); no new warning category/count.
- Independent review found no functional/security blocker. Its two UX findings were addressed: cancelled site/setup actions now report cancellation (two RED-to-GREEN regressions); confirmation wording correctly separates backup from update/restart.
- Actual RPM installation and real HTTP-probe acceptance were not repeated: external operations are isolated in these navigation tests; clone-server acceptance remains separate.
