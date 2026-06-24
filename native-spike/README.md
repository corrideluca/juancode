# juancode native spike (juancode-u34.1)

Throwaway go/no-go gate for the native macOS (Swift) port (epic `juancode-u34`).

## What it proves

1. **forkpty env fidelity.** A real `claude`/`codex` binary is spawned via
   `forkpty` + `execvp` (`PtyProcess.swift`). Because `execvp` inherits the
   process's `environ` and we never build an `envp`, the child env is **untouched** —
   no shadow `HOME`/`CODEX_HOME`, no `mcpServers` override. User-scope MCP
   (`~/.claude.json`), connectors, `~/.codex/config.toml` and project `.mcp.json`
   all resolve exactly as in a normal terminal. This is the CLAUDE.md prime directive,
   satisfied **by construction**.

2. **Externally-owned pty + SwiftTerm feed rendering.** The pty is owned by our code,
   not by SwiftTerm. We use a plain `TerminalView` and push bytes in with
   `feed(byteArray:)` (`main.swift`), deliberately **not** `LocalProcessTerminalView`
   (which bundles its own pty and would fight a shared registry). Keystrokes and
   resize flow back through `TerminalViewDelegate`. The real Claude Code TUI renders
   faithfully.

The `onData`/`subscribe` seam in `PtyProcess` is exactly the fan-out point that the
real registry (`juancode-u34.2`) will generalise to N subscribers (local SwiftUI view
+ remote WS clients).

## Run

```sh
swift run JuancodeSpike            # spawns `claude`
swift run JuancodeSpike codex      # spawns `codex`
swift run JuancodeSpike /bin/zsh   # any binary + args
```

A window opens with the live CLI. Env-fidelity diagnostics print to stderr at launch.

## Verdict: GO

Both risks cleared. Versions used: Swift 6.2.3 / Xcode 26.2 / SwiftTerm 1.13.0,
macOS arm64. Proceed to `juancode-u34.2` (Swift session registry + pty host with fan-out).
