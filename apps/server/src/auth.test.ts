import { afterEach, describe, expect, it, vi } from "vitest";
import type { IncomingMessage } from "node:http";

/**
 * The auth module reads JUANCODE_TOKEN once at import, so each test sets the env
 * and re-imports a fresh copy via vi.resetModules().
 */
async function loadAuth(token: string | undefined) {
  vi.resetModules();
  if (token === undefined) delete process.env.JUANCODE_TOKEN;
  else process.env.JUANCODE_TOKEN = token;
  return import("./auth.ts");
}

function req(headers: Record<string, string> = {}, url = "/api/x"): IncomingMessage {
  return { headers, url } as unknown as IncomingMessage;
}

afterEach(() => {
  delete process.env.JUANCODE_TOKEN;
});

/** Minimal Express res double capturing status/json/setHeader calls. */
function resDouble() {
  const calls = { status: 0, json: undefined as unknown, headers: {} as Record<string, string> };
  const res = {
    status(code: number) {
      calls.status = code;
      return res;
    },
    json(body: unknown) {
      calls.json = body;
      return res;
    },
    type() {
      return res;
    },
    send() {
      return res;
    },
    setHeader(name: string, value: string) {
      calls.headers[name] = value;
    },
  };
  return { res, calls };
}

describe("auth (disabled by default)", () => {
  it("middleware is pass-through when JUANCODE_TOKEN is unset", async () => {
    const a = await loadAuth(undefined);
    expect(a.authEnabled()).toBe(false);
    const { res, calls } = resDouble();
    let nexted = false;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    a.authMiddleware()(req() as any, res as any, () => {
      nexted = true;
    });
    expect(nexted).toBe(true);
    expect(calls.status).toBe(0); // never rejected
  });

  it("middleware is pass-through when JUANCODE_TOKEN is empty/whitespace", async () => {
    const a = await loadAuth("   ");
    expect(a.authEnabled()).toBe(false);
    const { res } = resDouble();
    let nexted = false;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    a.authMiddleware()(req() as any, res as any, () => {
      nexted = true;
    });
    expect(nexted).toBe(true);
  });

  it("WS verifier is pass-through when disabled", async () => {
    const a = await loadAuth(undefined);
    let destroyed = false;
    const sock = { write: () => true, destroy: () => (destroyed = true) };
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect(a.verifyWsUpgrade(req(), sock as any)).toBe(true);
    expect(destroyed).toBe(false);
  });
});

describe("auth (enabled)", () => {
  it("reports enabled and rejects a missing token", async () => {
    const a = await loadAuth("s3cret");
    expect(a.authEnabled()).toBe(true);
    expect(a.isAuthorized(req())).toBe(false);
  });

  it("accepts the token via Bearer header", async () => {
    const a = await loadAuth("s3cret");
    expect(a.isAuthorized(req({ authorization: "Bearer s3cret" }))).toBe(true);
    expect(a.isAuthorized(req({ authorization: "Bearer wrong" }))).toBe(false);
  });

  it("accepts the token via ?token= query param", async () => {
    const a = await loadAuth("s3cret");
    expect(a.isAuthorized(req({}, "/ws?token=s3cret"))).toBe(true);
    expect(a.isAuthorized(req({}, "/ws?token=nope"))).toBe(false);
  });

  it("accepts the token via cookie", async () => {
    const a = await loadAuth("s3cret");
    expect(a.isAuthorized(req({ cookie: "foo=bar; juancode_token=s3cret" }))).toBe(true);
    expect(a.isAuthorized(req({ cookie: "juancode_token=wrong" }))).toBe(false);
  });

  it("tokenMatches is constant-time-safe across lengths", async () => {
    const a = await loadAuth("s3cret");
    expect(a.tokenMatches("s3cret")).toBe(true);
    expect(a.tokenMatches("longer-wrong-token")).toBe(false);
    expect(a.tokenMatches("")).toBe(false);
    expect(a.tokenMatches(null)).toBe(false);
  });

  it("middleware rejects an unauthorized API request with 401", async () => {
    const a = await loadAuth("s3cret");
    const { res, calls } = resDouble();
    let nexted = false;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    a.authMiddleware()(req({ accept: "application/json" }) as any, res as any, () => {
      nexted = true;
    });
    expect(nexted).toBe(false);
    expect(calls.status).toBe(401);
  });

  it("middleware sets the cookie when authed via query token", async () => {
    const a = await loadAuth("s3cret");
    const { res, calls } = resDouble();
    let nexted = false;
    a.authMiddleware()(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      req({}, "/api/x?token=s3cret") as any,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      res as any,
      () => {
        nexted = true;
      },
    );
    expect(nexted).toBe(true);
    expect(calls.headers["Set-Cookie"]).toContain("juancode_token=s3cret");
    expect(calls.headers["Set-Cookie"]).toContain("HttpOnly");
  });

  it("WS verifier destroys the socket on a bad token", async () => {
    const a = await loadAuth("s3cret");
    let destroyed = false;
    const sock = { write: () => true, destroy: () => (destroyed = true) };
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect(a.verifyWsUpgrade(req({}, "/ws?token=bad"), sock as any)).toBe(false);
    expect(destroyed).toBe(true);
  });
});
