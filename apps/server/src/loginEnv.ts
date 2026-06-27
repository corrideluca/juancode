import { execFileSync } from "node:child_process";

/**
 * Capture the user's FULL login-shell environment so the genuine CLIs we spawn
 * (`claude` / `codex`) see exactly what they'd see in the user's terminal — even
 * when juancode itself was launched from a context with a stripped/minimal env
 * (Finder, launchd, an Electron `.app`, a systemd unit, …).
 *
 * juancode spawns the real CLI binaries directly (not through a shell), so unlike
 * the integrated terminal — which runs the user's interactive shell and re-sources
 * the rc files itself — a directly-spawned CLI only inherits this process's `env`.
 * Under a GUI launch that env lacks PATH entries and exported vars from
 * `~/.zprofile` / `~/.zshrc` (nvm/asdf bins, API keys, etc.), so the CLI can't find
 * its binary's tools or load credentials the way it does in a terminal.
 *
 * We fix that the same way {@link resolveBin} resolves binaries: ask the user's
 * login+interactive shell (`-lic`) to dump its `env`, parse it, and merge it onto
 * `process.env`. This AUGMENTS the live env — it never injects a shadow
 * HOME/CODEX_HOME or rewrites the user's config; faithful inheritance is the whole
 * point of this project. The capture runs once and is cached: a login shell is too
 * expensive to run per session spawn.
 */

/**
 * A unique marker we print on its own line right before dumping `env`, so we can
 * discard any banner/MOTD/noise the login shell emits before our payload. Picked
 * to be vanishingly unlikely to collide with a real environment line.
 */
const SENTINEL = "__JUANCODE_LOGIN_ENV__";

/** Keys whose value we keep from the live process even if the login shell sets a
 * different one — these describe THIS process / its runtime, not the user's shell
 * config, so the login-shell value would be wrong or irrelevant for our spawns. */
const LIVE_ENV_WINS = new Set(["PWD", "OLDPWD", "SHLVL", "_", "TMPDIR"]);

/**
 * Parse the `key=value` lines emitted by `env` (or a shell's builtin) into a map.
 *
 * Robust to the messy reality of login-shell output:
 *  - Drops everything up to and including the {@link SENTINEL} line (shell banners).
 *  - Values may contain `=`; only the first `=` splits key from value.
 *  - Values may span multiple lines (a var containing a newline) — a continuation
 *    line has no `KEY=` prefix, so it's appended to the current value.
 *  - Skips blank lines and anything before the first valid assignment.
 */
export function parseEnvDump(raw: string): Record<string, string> {
  const out: Record<string, string> = {};
  const sentinelAt = raw.lastIndexOf(SENTINEL);
  const body = sentinelAt === -1 ? raw : raw.slice(sentinelAt + SENTINEL.length);
  let currentKey: string | null = null;
  for (const line of body.split("\n")) {
    const eq = line.indexOf("=");
    // A valid assignment start: `KEY=...` where KEY is a plausible env name.
    if (eq > 0 && isEnvName(line.slice(0, eq))) {
      currentKey = line.slice(0, eq);
      out[currentKey] = line.slice(eq + 1);
    } else if (currentKey !== null && line !== "") {
      // Continuation of a multi-line value (e.g. a var with an embedded newline).
      out[currentKey] += `\n${line}`;
    }
  }
  return out;
}

/** True for strings that look like a POSIX env var name (`[A-Za-z_][A-Za-z0-9_]*`). */
function isEnvName(name: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(name);
}

/**
 * Merge a captured login-shell env onto the live process env.
 *
 * Precedence, by design:
 *  - The login-shell env is the base — it carries the PATH and exports the user
 *    sees in a terminal, which is exactly what a directly-spawned CLI is missing.
 *  - Live values for {@link LIVE_ENV_WINS} keys override (process-specific state).
 *  - Any key present ONLY in the live env (e.g. vars juancode/Electron injected,
 *    or `JUANCODE_*` overrides) is preserved — we never drop a live var.
 *
 * The result is a faithful superset: everything the terminal would have, plus
 * anything specific to this running process.
 */
export function mergeLoginEnv(
  live: Record<string, string | undefined>,
  login: Record<string, string>,
): Record<string, string> {
  const merged: Record<string, string> = {};
  // Start from login-shell env (the values a terminal would have).
  for (const [k, v] of Object.entries(login)) merged[k] = v;
  // Layer the live env on top, but only where it should win or is unique.
  for (const [k, v] of Object.entries(live)) {
    if (v === undefined) continue;
    if (LIVE_ENV_WINS.has(k) || !(k in merged)) merged[k] = v;
  }
  return merged;
}

let cached: Record<string, string> | null = null;

/**
 * Run the user's login+interactive shell once, dump its `env`, and cache the
 * result merged onto `process.env`. Subsequent calls return the cache.
 *
 * Resilient: if the shell is missing, times out, or emits nothing parseable we
 * fall back to the live `process.env` unchanged — never worse than today.
 */
export function getLoginEnv(): Record<string, string> {
  if (cached) return cached;
  cached = captureLoginEnv();
  return cached;
}

/** Reset the cache. Test-only seam. */
export function resetLoginEnvCache(): void {
  cached = null;
}

function captureLoginEnv(): Record<string, string> {
  const liveEnv = process.env as Record<string, string | undefined>;
  const shell = liveEnv.SHELL ?? "/bin/zsh";
  try {
    // `printf '%s\n'` emits the sentinel without a trailing shell builtin that
    // might be aliased; `env` then dumps the full exported environment.
    const out = execFileSync(shell, ["-lic", `printf '%s\\n' ${SENTINEL}; env`], {
      encoding: "utf8",
      timeout: 5000,
      maxBuffer: 4 * 1024 * 1024,
      stdio: ["ignore", "pipe", "ignore"],
    });
    const login = parseEnvDump(out);
    // No usable PATH means the dump didn't really come from the login shell —
    // don't trust a partial capture; keep the live env as-is.
    if (!login.PATH) return materialize(liveEnv);
    return mergeLoginEnv(liveEnv, login);
  } catch {
    // No shell, timeout, or non-zero exit — fall back to the live env unchanged.
    return materialize(liveEnv);
  }
}

/** Strip undefined values so the result is a clean `Record<string, string>`. */
function materialize(env: Record<string, string | undefined>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) if (v !== undefined) out[k] = v;
  return out;
}
