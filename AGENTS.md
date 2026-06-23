# AGENTS.md

## What juancode is

A **light web harness** for running the real `claude` (Claude Code) and `codex` CLIs
from a browser. Unlike t3code, it does **not** reimplement the agents or their MCP
plumbing — it spawns the genuine CLI binaries in a pseudo-terminal (`node-pty`) with
the user's environment inherited untouched. That means user-scope MCP servers
(`~/.claude.json`), account connectors, `~/.codex/config.toml`, and project `.mcp.json`
all load exactly as they do in a normal terminal. Preserving that faithfulness is the
core value of this project — never inject a shadow `HOME`/`CODEX_HOME` or override
`mcpServers`.

## Stack

- **Backend** `apps/server`: Express 5 + `ws` + `node-pty` + `better-sqlite3`, TypeScript, run via `tsx`.
- **Frontend** `apps/web`: Vite + React 19 + TanStack Router + TanStack Query + Tailwind v4 + xterm.js.
- pnpm workspaces, Node ≥ 22.

## Architecture (one paragraph)

The browser holds one shared WebSocket (`apps/web/src/lib/socket.ts`) to the server's
`/ws`. Each session is one pty running a real CLI (`apps/server/src/session.ts`),
tracked live in an in-memory registry and persisted (metadata + capped scrollback) to
sqlite (`apps/server/src/db.ts`) so history survives restarts. xterm.js renders the pty
stream faithfully; keystrokes flow back as `input` messages. The wire protocol lives in
`apps/server/src/protocol.ts` and is mirrored in `apps/web/src/protocol.ts` — **keep the
two in sync**.

## UI components — IMPORTANT

Before building any non-trivial UI component from scratch, first check
**https://github.com/brillout/awesome-react-components** for a well-maintained existing
library that fits. Prefer a vetted component over a hand-rolled one. Only build custom
when nothing suitable exists or the dependency cost isn't justified.

## Conventions

- All TypeScript. `verbatimModuleSyntax` is on — use `import type` for type-only imports.
- Use real newlines, not escaped ones, in any generated content.
- Prefer extracting shared logic into a module over duplicating it across files.

## Before considering a task done

Run from the repo root:

- `pnpm typecheck`
- `pnpm lint`
- `pnpm test`

(`pnpm check` runs all three.) A Husky pre-commit hook runs eslint + prettier + related
vitest on staged files.

## Run it locally

- `pnpm dev` — runs server (`:4280`) and web (`:5280`) together. Open http://localhost:5280.
- Requires `claude` and/or `codex` on PATH and authenticated. Override binary paths with
  `JUANCODE_CLAUDE_BIN` / `JUANCODE_CODEX_BIN` if needed.

<!-- BEGIN BEADS INTEGRATION -->
## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why bd?

- Dependency-aware: Track blockers and relationships between issues
- Git-friendly: Auto-syncs to JSONL for version control
- Agent-optimized: JSON output, ready work detection, discovered-from links
- Prevents duplicate tracking systems and confusion

### Quick Start

**Check for ready work:**

```bash
bd ready --json
```

**Create new issues:**

```bash
bd create "Issue title" --description="Detailed context" -t bug|feature|task -p 0-4 --json
bd create "Issue title" --description="What this issue is about" -p 1 --deps discovered-from:bd-123 --json
```

**Claim and update:**

```bash
bd update bd-42 --status in_progress --json
bd update bd-42 --priority 1 --json
```

**Complete work:**

```bash
bd close bd-42 --reason "Completed" --json
```

### Issue Types

- `bug` - Something broken
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature with subtasks
- `chore` - Maintenance (dependencies, tooling)

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (default, nice-to-have)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Workflow for AI Agents

1. **Check ready work**: `bd ready` shows unblocked issues
2. **Claim your task**: `bd update <id> --status in_progress`
3. **Work on it**: Implement, test, document
4. **Discover new work?** Create linked issue:
   - `bd create "Found bug" --description="Details about what was found" -p 1 --deps discovered-from:<parent-id>`
5. **Complete**: `bd close <id> --reason "Done"`

### Auto-Sync

bd automatically syncs with git:

- Exports to `.beads/issues.jsonl` after changes (5s debounce)
- Imports from JSONL when newer (e.g., after `git pull`)
- No manual export/import needed!

### Important Rules

- ✅ Use bd for ALL task tracking
- ✅ Always use `--json` flag for programmatic use
- ✅ Link discovered work with `discovered-from` dependencies
- ✅ Check `bd ready` before asking "what should I work on?"
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT use external issue trackers
- ❌ Do NOT duplicate tracking systems

For more details, see README.md and docs/QUICKSTART.md.

<!-- END BEADS INTEGRATION -->

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
