import { useNavigate } from "@tanstack/react-router";
import { dismissHealth, useHealthReports } from "../lib/health.ts";
import type { SessionMeta } from "../protocol.ts";

/**
 * Surfaces the periodic health-check sweep — pillar 3 of the orchestration loop
 * (juancode-02k). Lists sessions the server flagged as dead (pty gone) or stale
 * (a busy turn that's gone quiet), offering a jump-to-session that reactivates a
 * dead+resumable one, plus a per-row dismiss. Renders nothing when all is well.
 */
export function HealthAlert({
  sessions,
  onNavigate,
}: {
  sessions: SessionMeta[];
  onNavigate?: () => void;
}) {
  const navigate = useNavigate();
  const reports = useHealthReports();
  if (reports.length === 0) return null;

  const titleFor = (id: string) => sessions.find((s) => s.id === id)?.title ?? id;

  return (
    <div className="border-b border-amber-900/50 bg-amber-950/30 px-3 py-2">
      <p className="mb-1.5 flex items-center gap-1.5 text-[11px] font-medium tracking-wide text-amber-300/90 uppercase">
        <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-amber-400" />
        Needs attention
      </p>
      <ul className="flex flex-col gap-1">
        {reports.map((r) => {
          const dead = r.state === "dead";
          // A dead+resumable session reactivates on open; otherwise just jump to it.
          const action = dead && r.resumable ? "Reactivate" : "Go to";
          return (
            <li
              key={r.id}
              className="flex items-center gap-2 rounded-md bg-neutral-900/60 px-2 py-1.5 text-xs"
            >
              <span
                title={dead ? "Session exited / pty gone" : "Busy turn has stalled (no output)"}
                className="shrink-0"
              >
                {dead ? "💀" : "⏳"}
              </span>
              <span className="min-w-0 flex-1 truncate text-neutral-300">{titleFor(r.id)}</span>
              <button
                type="button"
                onClick={() => {
                  onNavigate?.();
                  void navigate({ to: "/session/$id", params: { id: r.id } });
                }}
                className="shrink-0 rounded px-1.5 py-0.5 text-amber-300 hover:bg-neutral-800 hover:text-amber-200"
              >
                {action}
              </button>
              <button
                type="button"
                title="Dismiss until it recovers and re-fails"
                onClick={() => dismissHealth(r.id)}
                className="shrink-0 rounded px-1 text-neutral-500 hover:bg-neutral-800 hover:text-neutral-300"
              >
                ✕
              </button>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
