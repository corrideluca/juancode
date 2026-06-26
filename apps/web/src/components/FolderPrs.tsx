import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useQuery } from "@tanstack/react-query";
import { api } from "../lib/api.ts";
import type { ProviderId, PrChecks, PullRequest, TrackState } from "../protocol.ts";
import { resolveTrackNotification, trackPr, untrackPr, useTrackedPr } from "../lib/trackedPrs.ts";

/** Build the single-line seed prompt auto-submitted to a PR-context session. */
function prPrompt(pr: PullRequest): string {
  return `Please help me work on pull request #${pr.number} "${pr.title}" (branch ${pr.branch}): ${pr.url} — start by reviewing the PR and its diff.`;
}

const CHECK_STYLE: Record<PrChecks, { dot: string; text: string; label: string }> = {
  passing: { dot: "bg-emerald-500", text: "text-emerald-400", label: "Checks passing" },
  failing: { dot: "bg-red-500", text: "text-red-400", label: "Checks failing" },
  pending: { dot: "bg-amber-500", text: "text-amber-400", label: "Checks running" },
  none: { dot: "bg-neutral-600", text: "text-neutral-500", label: "No checks" },
};

const TRACK_STYLE: Record<TrackState, { text: string; label: string }> = {
  watching: { text: "text-sky-400", label: "Watching" },
  fixing: { text: "text-amber-400", label: "Fixing" },
  needs_decision: { text: "text-red-400", label: "Needs decision" },
};

const POPOVER_WIDTH = 288; // w-72

interface Props {
  cwd: string;
  /** Spawn a session in `cwd`, optionally seeding it with initial input. */
  onNewSession: (
    provider: ProviderId,
    cwd: string,
    initialInput?: string,
    skipPermissions?: boolean,
  ) => void;
}

/**
 * Per-folder open-PR badge with a popover. Renders nothing when the folder isn't
 * a GitHub repo or has no open PRs, so it stays invisible unless useful.
 */
export function FolderPrs({ cwd, onNewSession }: Props) {
  const [open, setOpen] = useState(false);
  const [mineOnly, setMineOnly] = useState(false);
  const [query, setQuery] = useState("");
  const btnRef = useRef<HTMLButtonElement>(null);
  const popRef = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ top: number; left: number } | null>(null);
  const prs = useQuery({
    queryKey: ["prs", cwd],
    queryFn: () => api.prs(cwd),
    refetchInterval: 30_000,
    staleTime: 15_000,
  });

  // The sidebar's <nav> is overflow-scrolling, which clips an in-flow popover on
  // the left. Render it in a portal with fixed positioning anchored to the badge,
  // right-aligned to the badge's right edge and clamped to the viewport.
  useLayoutEffect(() => {
    if (!open) return;
    const place = () => {
      const r = btnRef.current?.getBoundingClientRect();
      if (!r) return;
      const left = Math.max(8, Math.min(r.right - POPOVER_WIDTH, window.innerWidth - POPOVER_WIDTH - 8));
      setPos({ top: r.bottom + 4, left });
    };
    place();
    window.addEventListener("scroll", place, true);
    window.addEventListener("resize", place);
    return () => {
      window.removeEventListener("scroll", place, true);
      window.removeEventListener("resize", place);
    };
  }, [open]);

  // Close on outside click / Escape. The popover lives in a portal outside the
  // React root, so we test containment against the actual DOM nodes rather than
  // relying on synthetic event propagation crossing the portal boundary.
  useEffect(() => {
    if (!open) return;
    const onClick = (e: MouseEvent) => {
      const t = e.target as Node;
      if (btnRef.current?.contains(t) || popRef.current?.contains(t)) return;
      setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    window.addEventListener("click", onClick);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", onClick);
      window.removeEventListener("keydown", onKey);
    };
  }, [open]);

  const all = prs.data?.available ? prs.data.prs : [];
  const viewer = prs.data?.viewer ?? "";
  const mineCount = viewer ? all.filter((pr) => pr.author === viewer).length : 0;
  // Offer the "mine" filter whenever we know who the viewer is and a filter is meaningful.
  const canFilterMine = viewer !== "" && all.length > 1;
  const q = query.trim().toLowerCase();
  const list = all.filter((pr) => {
    if (mineOnly && canFilterMine && pr.author !== viewer) return false;
    if (q && !`#${pr.number} ${pr.title} ${pr.branch}`.toLowerCase().includes(q)) return false;
    return true;
  });
  if (all.length === 0) return null;

  return (
    <span className="relative">
      <button
        ref={btnRef}
        type="button"
        title={`${all.length} open pull request${all.length === 1 ? "" : "s"}`}
        onClick={(e) => {
          e.preventDefault();
          e.stopPropagation();
          setOpen((cur) => !cur);
        }}
        className="rounded bg-neutral-800 px-1.5 text-[10px] font-medium text-neutral-300 hover:bg-neutral-700"
      >
        {all.length} PR{all.length === 1 ? "" : "s"}
      </button>
      {open &&
        pos &&
        createPortal(
          <div
            ref={popRef}
            onClick={(e) => e.stopPropagation()}
            style={{ position: "fixed", top: pos.top, left: pos.left, width: POPOVER_WIDTH }}
            className="z-50 max-h-80 overflow-y-auto rounded-md border border-neutral-700 bg-neutral-900 pb-1 shadow-lg"
          >
          <div className="sticky top-0 z-10 flex items-center gap-1.5 border-b border-neutral-800 bg-neutral-900 px-2 py-1.5">
            <input
              type="text"
              autoFocus
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Filter PRs…"
              className="min-w-0 flex-1 rounded border border-neutral-700 bg-neutral-800 px-2 py-1 text-[11px] text-neutral-200 placeholder:text-neutral-500 focus:border-neutral-500 focus:outline-none"
            />
            {canFilterMine && (
              <button
                type="button"
                onClick={() => setMineOnly((cur) => !cur)}
                className={`shrink-0 rounded px-1.5 py-1 text-[10px] font-medium transition-colors ${
                  mineOnly
                    ? "bg-sky-600/30 text-sky-300 hover:bg-sky-600/40"
                    : "bg-neutral-800 text-neutral-400 hover:bg-neutral-700"
                }`}
              >
                Mine ({mineCount})
              </button>
            )}
          </div>
          {list.length === 0 && (
            <div className="px-2 py-2 text-center text-[11px] text-neutral-500">
              {q || mineOnly ? "No matching PRs" : "No open PRs"}
            </div>
          )}
          {list.map((pr) => (
            <PrRow
              key={pr.number}
              pr={pr}
              cwd={cwd}
              onSpawn={() => {
                setOpen(false);
                onNewSession("claude", cwd, prPrompt(pr));
              }}
            />
          ))}
          </div>,
          document.body,
        )}
    </span>
  );
}

/**
 * One PR in the popover, with its CI badge, "+ session" / "Open" actions, and the
 * Track toggle (juancode-bt2). When tracked, shows the live tracking state and any
 * outstanding needs-decision notifications (dismissable). Tracking is driven over
 * the wire — `trackPr` spawns the agent session server-side.
 */
function PrRow({ pr, cwd, onSpawn }: { pr: PullRequest; cwd: string; onSpawn: () => void }) {
  const check = CHECK_STYLE[pr.checks];
  const tracked = useTrackedPr(cwd, pr.number);
  const track = tracked ? TRACK_STYLE[tracked.state] : null;
  return (
    <div className="px-2 py-1.5 hover:bg-neutral-800/60">
      <div className="flex items-center gap-1.5">
        <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${check.dot}`} title={check.label} />
        <a
          href={pr.url}
          target="_blank"
          rel="noreferrer"
          onClick={(e) => e.stopPropagation()}
          className="truncate text-xs text-neutral-200 hover:underline"
          title={pr.title}
        >
          <span className="text-neutral-500">#{pr.number}</span> {pr.title}
        </a>
        {pr.draft && (
          <span className="shrink-0 rounded bg-neutral-700 px-1 text-[9px] text-neutral-300">draft</span>
        )}
      </div>
      <div className="mt-1 flex items-center gap-2 pl-3 text-[11px]">
        <a
          href={pr.url}
          target="_blank"
          rel="noreferrer"
          onClick={(e) => e.stopPropagation()}
          className="text-sky-400 hover:underline"
        >
          Open ↗
        </a>
        <button
          type="button"
          onClick={(e) => {
            e.preventDefault();
            e.stopPropagation();
            onSpawn();
          }}
          className="rounded px-1 text-neutral-300 transition-colors hover:bg-neutral-800 hover:text-neutral-100"
        >
          ＋ session
        </button>
        <button
          type="button"
          onClick={(e) => {
            e.preventDefault();
            e.stopPropagation();
            if (tracked) untrackPr(tracked.id);
            else trackPr(cwd, pr);
          }}
          className={`rounded px-1 transition-colors ${
            tracked
              ? "bg-sky-600/30 text-sky-300 hover:bg-sky-600/40"
              : "text-neutral-300 hover:bg-neutral-800 hover:text-neutral-100"
          }`}
          title={tracked ? "Stop tracking this PR" : "Track this PR (auto-fix + escalate)"}
        >
          {tracked ? "Tracking" : "Track"}
        </button>
        <span className={`ml-auto shrink-0 ${track ? track.text : check.text}`} title={track ? track.label : check.label}>
          {track ? track.label : check.label}
        </span>
      </div>
      {tracked && tracked.notifications.length > 0 && (
        <div className="mt-1 ml-3 space-y-1">
          {tracked.notifications.map((n) => (
            <div
              key={n.id}
              className="flex items-start gap-1.5 rounded border border-red-500/30 bg-red-500/10 px-1.5 py-1 text-[10px] text-red-200"
            >
              <span className="min-w-0 flex-1">{n.message}</span>
              <button
                type="button"
                onClick={(e) => {
                  e.preventDefault();
                  e.stopPropagation();
                  resolveTrackNotification(tracked.id, n.id);
                }}
                className="shrink-0 rounded px-1 text-red-300 hover:bg-red-500/20"
                title="Dismiss"
              >
                ✕
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
