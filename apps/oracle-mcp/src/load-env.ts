// Minimal, dependency-free `.env` loader for the Oracle sidecar. We deliberately do
// NOT pull in `dotenv`: this only needs to seed a couple of config vars (the Telegram
// bot token + allowlist) from a local file when the sidecar isn't launched from a
// shell that already exported them (e.g. a launchd agent or a bare `pnpm start`).
//
// Faithful-to-the-environment rule (see AGENTS.md): a real shell export always wins.
// We only set keys that are NOT already present in `process.env`, so the file is a
// fallback default, never an override of the inherited environment.

import { readFileSync } from "node:fs";

/** Parse `.env` text into key/value pairs. Supports `KEY=value`, `export KEY=value`,
 *  `#` comments, blank lines, and single/double-quoted values. Values are taken
 *  verbatim (no escape processing) beyond stripping surrounding quotes. */
export function parseEnv(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const withoutExport = line.startsWith("export ") ? line.slice(7).trim() : line;
    const eq = withoutExport.indexOf("=");
    if (eq <= 0) continue;
    const key = withoutExport.slice(0, eq).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) continue;
    let value = withoutExport.slice(eq + 1).trim();
    if (
      value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'")))
    ) {
      value = value.slice(1, -1);
    }
    out[key] = value;
  }
  return out;
}

/** Load `path` into `env`, setting only keys that aren't already present (an
 *  inherited shell export always wins). A missing/unreadable file is a silent no-op.
 *  Returns the list of keys it actually set (for logging/tests). */
export function loadEnvFile(path: string, env: NodeJS.ProcessEnv = process.env): string[] {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return [];
  }
  const set: string[] = [];
  for (const [key, value] of Object.entries(parseEnv(text))) {
    if (env[key] === undefined) {
      env[key] = value;
      set.push(key);
    }
  }
  return set;
}
