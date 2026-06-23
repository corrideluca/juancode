import type {
  BeadsResult,
  CommentSide,
  DiffComment,
  DiffResult,
  PrListResult,
  ProviderId,
  ReviewResult,
  SessionMeta,
} from "../protocol.ts";

export interface ProviderInfo {
  id: ProviderId;
  label: string;
}

export interface DirEntry {
  name: string;
  path: string;
}

export interface DirListing {
  path: string;
  parent: string | null;
  entries: DirEntry[];
  /** True when `entries` are recursive search matches rather than direct children. */
  search: boolean;
}

export type McpHealth =
  | "connected"
  | "needs-auth"
  | "pending"
  | "failed"
  | "enabled"
  | "disabled"
  | "unknown";

export interface McpServerStatus {
  name: string;
  detail: string;
  transport: string | null;
  health: McpHealth;
  statusLabel: string;
  auth: string | null;
}

export interface ProviderStatus {
  id: ProviderId;
  label: string;
  command: string;
  available: boolean;
  version: string | null;
  warning: string | null;
  error: string | null;
  mcpServers: McpServerStatus[];
}

async function getJson<T>(url: string): Promise<T> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return (await res.json()) as T;
}

async function sendJson<T>(url: string, method: string, body?: unknown): Promise<T> {
  const res = await fetch(url, {
    method,
    headers: body === undefined ? undefined : { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return (res.status === 204 ? undefined : await res.json()) as T;
}

export interface NewComment {
  file: string;
  side: CommentSide;
  line: number;
  /** Inclusive end of the line range; omit for a single-line comment. */
  endLine?: number;
  body: string;
}

export const api = {
  providers: () => getJson<ProviderInfo[]>("/api/providers"),
  status: () => getJson<ProviderStatus[]>("/api/status"),
  sessions: () => getJson<SessionMeta[]>("/api/sessions"),
  deleteSession: (id: string) => sendJson<void>(`/api/sessions/${id}`, "DELETE"),
  dirs: (path?: string, q?: string) => {
    const params = new URLSearchParams();
    if (path) params.set("path", path);
    if (q) params.set("q", q);
    const qs = params.toString();
    return getJson<DirListing>(`/api/dirs${qs ? `?${qs}` : ""}`);
  },
  prs: (cwd: string) => getJson<PrListResult>(`/api/prs?cwd=${encodeURIComponent(cwd)}`),
  diff: (id: string) => getJson<DiffResult>(`/api/sessions/${id}/diff`),
  beads: (id: string) => getJson<BeadsResult>(`/api/sessions/${id}/beads`),
  comments: (id: string) => getJson<DiffComment[]>(`/api/sessions/${id}/comments`),
  addComment: (id: string, c: NewComment) =>
    sendJson<DiffComment>(`/api/sessions/${id}/comments`, "POST", c),
  deleteComment: (id: string, commentId: string) =>
    sendJson<void>(`/api/sessions/${id}/comments/${commentId}`, "DELETE"),
  clearComments: (id: string) => sendJson<void>(`/api/sessions/${id}/comments`, "DELETE"),
  review: (id: string) => getJson<ReviewResult | null>(`/api/sessions/${id}/review`),
  runReview: (id: string) => sendJson<ReviewResult>(`/api/sessions/${id}/review`, "POST"),
  /** Upload a dragged file's bytes; returns the absolute path the server saved it to. */
  uploadFile: async (file: File): Promise<{ path: string }> => {
    const res = await fetch(`/api/uploads?name=${encodeURIComponent(file.name)}`, {
      method: "POST",
      headers: { "Content-Type": file.type || "application/octet-stream" },
      body: file,
    });
    if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
    return (await res.json()) as { path: string };
  },
};
