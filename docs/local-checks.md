# Opt-in local checks

Install Bun **1.2.20** explicitly, matching the CLI @types/bun line, then run `cd cli && bun install --frozen-lockfile`. packageManager records that pin. Hook never installs dependencies.

## Installation and push contract

Enable explicitly with `bash scripts/install-hooks.sh` using Bash/Git Bash. Windows-target repositories also provide `pwsh -NoProfile -File scripts/install-hooks.ps1`. Installer is idempotent and refuses to hide existing active hooks or replace custom core.hooksPath. Relative repository-local .githooks resolves within each linked worktree. It is never installed automatically.

Every nondeleted ref must resolve to checked-out HEAD. Checks require a clean checkout including nonignored untracked files. No stash, rewriting, fetch or actual push occurs. New refs, unavailable bases, empty input/ranges, deletions, renames and shared changes broaden to full project checks. Multiple refs are consumed before one validation. Deleted refs alone skip. Other commits need their own clean checkout.

## Commands and acceptance

`bun run --cwd cli typecheck` over the full existing CLI tsconfig, never individual files. No invented lint or format policy. No game, UE4SS install, executable build or application launch.

CLI locked install and typecheck passed under Bun 1.2.20 in secret-free Linux Boat. Windows executable rebuild and Lua/game behavior remain separate native gates.

`python3 scripts/hooks/test-hooks.py` exercises executable hooks and installers in disposable Git repositories with stub project commands, including linked worktrees. No actual push. Harness evidence is separate from actual project/native acceptance. No under-nine-second promise, CI activation or affected-only optimization is claimed. No user hooks were installed during preparation.
