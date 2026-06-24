/**
 * Client-side token handling for opt-in remote auth.
 *
 * On first load with `?token=<token>` in the URL, the token is captured into
 * localStorage and stripped from the address bar (the server, seeing the query
 * token, sets an httpOnly cookie so same-origin requests carry it thereafter).
 * `getToken()` returns the stored token (if any) for callers that can't rely on
 * the cookie — notably the WebSocket URL.
 *
 * When auth is disabled on the server there is simply never a token and every
 * code path here is inert.
 */

const STORAGE_KEY = "juancode_token";

/** Pull a `?token=` from the URL into storage and clean the address bar. */
function captureTokenFromUrl(): void {
  if (typeof window === "undefined") return;
  const params = new URLSearchParams(window.location.search);
  const token = params.get("token");
  if (!token) return;
  try {
    window.localStorage.setItem(STORAGE_KEY, token);
  } catch {
    /* storage unavailable (private mode) — fall back to in-memory below */
  }
  inMemoryToken = token;
  params.delete("token");
  const qs = params.toString();
  const url = window.location.pathname + (qs ? `?${qs}` : "") + window.location.hash;
  window.history.replaceState(null, "", url);
}

let inMemoryToken: string | null = null;

// Capture at module load, before anything reads the token.
captureTokenFromUrl();

export function getToken(): string | null {
  if (inMemoryToken) return inMemoryToken;
  try {
    return window.localStorage.getItem(STORAGE_KEY);
  } catch {
    return null;
  }
}

export function setToken(token: string): void {
  inMemoryToken = token;
  try {
    window.localStorage.setItem(STORAGE_KEY, token);
  } catch {
    /* ignore */
  }
}

export function clearToken(): void {
  inMemoryToken = null;
  try {
    window.localStorage.removeItem(STORAGE_KEY);
  } catch {
    /* ignore */
  }
}

/** Re-authenticate: prompt for a token and reload so the cookie is re-set. */
export function promptForToken(): void {
  // Guard against multiple concurrent 401s firing the prompt repeatedly.
  if (authPrompting) return;
  authPrompting = true;
  const entered = window.prompt(
    "This juancode server requires an access token. Paste it to continue:",
    "",
  );
  if (entered && entered.trim()) {
    setToken(entered.trim());
    // Reload via ?token= so the server sets the httpOnly cookie for the session.
    window.location.href = `/?token=${encodeURIComponent(entered.trim())}`;
  } else {
    authPrompting = false;
  }
}

let authPrompting = false;
