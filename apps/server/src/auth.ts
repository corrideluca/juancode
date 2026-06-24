import { timingSafeEqual } from "node:crypto";
import type { IncomingMessage } from "node:http";
import type { NextFunction, Request, RequestHandler, Response } from "express";

/**
 * Opt-in token auth for remote/mobile access.
 *
 * When `JUANCODE_TOKEN` is unset/empty, auth is a complete no-op — behaviour is
 * identical to plain localhost usage. When it is set, every HTTP request and the
 * WebSocket upgrade must carry the matching token. The token is accepted three
 * ways (most → least convenient for a browser):
 *   1. an httpOnly `juancode_token` cookie (set after the first authenticated load)
 *   2. a `?token=<token>` query param (works for WS/EventSource and bookmarks)
 *   3. an `Authorization: Bearer <token>` header
 *
 * The token is the ONLY thing between the public internet and a shell — pair it
 * with a tunnel (see README "Remote access") and treat it like a password.
 */

export const COOKIE_NAME = "juancode_token";

/** The configured token, or "" when auth is disabled. Read once at import. */
const TOKEN = (process.env.JUANCODE_TOKEN ?? "").trim();

export function authEnabled(): boolean {
  return TOKEN.length > 0;
}

/** Constant-time string comparison that doesn't leak length via early return. */
function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  // timingSafeEqual throws on length mismatch; compare against a fixed-length
  // digestable buffer to keep the comparison constant-time regardless.
  if (ab.length !== bb.length) {
    // Still run a comparison so timing doesn't reveal the length difference.
    timingSafeEqual(ab, ab);
    return false;
  }
  return timingSafeEqual(ab, bb);
}

export function tokenMatches(candidate: string | null | undefined): boolean {
  if (!candidate) return false;
  return safeEqual(candidate, TOKEN);
}

/** Minimal cookie-header parser (avoids pulling in cookie-parser). */
function parseCookie(header: string | undefined, name: string): string | null {
  if (!header) return null;
  for (const part of header.split(";")) {
    const eq = part.indexOf("=");
    if (eq === -1) continue;
    if (part.slice(0, eq).trim() === name) {
      return decodeURIComponent(part.slice(eq + 1).trim());
    }
  }
  return null;
}

/** Extract a candidate token from header, query string, or cookie. */
export function extractToken(req: IncomingMessage): string | null {
  const auth = req.headers["authorization"];
  if (typeof auth === "string" && auth.startsWith("Bearer ")) {
    return auth.slice("Bearer ".length).trim();
  }
  // req.url is path + query for both Express requests and raw upgrade requests.
  const url = req.url ?? "";
  const qi = url.indexOf("?");
  if (qi !== -1) {
    const qp = new URLSearchParams(url.slice(qi + 1)).get("token");
    if (qp) return qp;
  }
  return parseCookie(req.headers["cookie"], COOKIE_NAME);
}

/** True when the request carries a valid token (any of the accepted forms). */
export function isAuthorized(req: IncomingMessage): boolean {
  return tokenMatches(extractToken(req));
}

const COOKIE_MAX_AGE_DAYS = 30;

/** Serialize the auth cookie. `secure` is set when the request arrived over TLS. */
function authCookie(value: string, secure: boolean): string {
  const parts = [
    `${COOKIE_NAME}=${encodeURIComponent(value)}`,
    "HttpOnly",
    "Path=/",
    "SameSite=Lax",
    `Max-Age=${COOKIE_MAX_AGE_DAYS * 24 * 60 * 60}`,
  ];
  if (secure) parts.push("Secure");
  return parts.join("; ");
}

function isSecureRequest(req: Request): boolean {
  return req.secure || req.headers["x-forwarded-proto"] === "https";
}

/**
 * Express auth middleware. Pass-through when auth is disabled. Otherwise rejects
 * unauthorized requests with 401. When a valid token arrives via query/header it
 * also (re)sets the httpOnly cookie so subsequent same-origin requests + the WS
 * upgrade carry it automatically.
 */
/** Minimal self-contained login page served to unauthorized browser navigations. */
function loginPage(): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>juancode — sign in</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center;
    font-family: ui-sans-serif, system-ui, -apple-system, sans-serif; background:#0b0d10; color:#e5e5e5; }
  form { width:min(92vw,22rem); display:flex; flex-direction:column; gap:.75rem; padding:1.5rem;
    border:1px solid #262626; border-radius:.75rem; background:#0a0a0a; }
  h1 { margin:0; font-size:1rem; font-weight:600; }
  p { margin:0; font-size:.8rem; color:#a3a3a3; }
  input { padding:.6rem .7rem; border-radius:.5rem; border:1px solid #404040; background:#171717;
    color:#fafafa; font-size:1rem; }
  button { padding:.6rem .7rem; border-radius:.5rem; border:0; background:#404040; color:#fafafa;
    font-size:.9rem; font-weight:600; cursor:pointer; }
  button:hover { background:#525252; }
</style></head><body>
<form onsubmit="event.preventDefault();var t=encodeURIComponent(this.token.value.trim());if(t)location.href='/?token='+t;">
  <h1>juancode</h1>
  <p>Enter your access token to continue.</p>
  <input name="token" type="password" autocomplete="current-password" autofocus placeholder="Access token" />
  <button type="submit">Sign in</button>
</form></body></html>`;
}

export function authMiddleware(): RequestHandler {
  return (req: Request, res: Response, next: NextFunction) => {
    if (!authEnabled()) return next();
    if (!isAuthorized(req)) {
      // Serve a login page to browser navigations; JSON for API/XHR callers.
      const accept = req.headers["accept"] ?? "";
      if (req.method === "GET" && accept.includes("text/html")) {
        res.status(401).type("html").send(loginPage());
        return;
      }
      res.status(401).json({ error: "unauthorized", authRequired: true });
      return;
    }
    // Persist the token as a cookie when it came in via query/header so the SPA
    // and WS work after the first authenticated load without re-passing ?token=.
    const fromCookie = parseCookie(req.headers["cookie"], COOKIE_NAME);
    if (!fromCookie || !tokenMatches(fromCookie)) {
      const tok = extractToken(req);
      if (tok) res.setHeader("Set-Cookie", authCookie(tok, isSecureRequest(req)));
    }
    next();
  };
}

/**
 * Gate a WebSocket upgrade. Returns true when the upgrade may proceed. On
 * failure it writes a 401 and destroys the socket so the handshake never
 * completes. Pass-through (always true) when auth is disabled.
 */
export function verifyWsUpgrade(req: IncomingMessage, socket: NodeJS.WritableStream & { destroy: () => void }): boolean {
  if (!authEnabled()) return true;
  if (isAuthorized(req)) return true;
  try {
    socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
  } catch {
    /* socket may already be gone */
  }
  socket.destroy();
  return false;
}
