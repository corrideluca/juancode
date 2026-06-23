import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { api } from "../lib/api.ts";
import type { ProviderId, PrChecks, PullRequest } from "../protocol.ts";

/** Build the single-line seed prompt auto-submitted to a PR-context session. */
function prPrompt(pr: PullRequest): string {
  return `Please help me work on pull request #${pr.number} "${pr.title}" (branch ${pr.branch}): ${pr.url} — start by reviewing the PR and its diff.`;
}

const CHECK_STYLE: Record<PrChecks, { dot: string; label: string }> = {
  passing: { dot: "bg-emerald-500", label: "Checks passing" },
  failing: { dot: "bg-red-500", label: "Checks failing" },
  pending: { dot: "bg-amber-500", label: "Checks running" },
  none: { dot: "bg-neutral-600", label: "No checks" },
};

interface Props {
  cwd: string;
  /** Spawn a session in `cwd`, optionally seeding it with initial input. */
  onNewSession: (provider: ProviderId, cwd: string, initialInput?: string) => void;
}

/**
 * Per-folder open-PR badge with a popover. Renders nothing when the folder isn't
 * a GitHub repo or has no open PRs, so it stays invisible unless useful.
 */
export function FolderPrs({ cwd, onNewSession }: Props) {
  const [open, setOpen] = useState(false);
  const prs = useQuery({
    queryKey: ["prs", cwd],
    queryFn: () => api.prs(cwd),
    refetchInterval: 30_000,
    staleTime: 15_000,
  });

  // Close the popover on any outside click / Escape.
  useEffect(() => {
    if (!open) return;
    const close = () => setOpen(false);
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    window.addEventListener("click", close);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("keydown", onKey);
    };
  }, [open]);

  const list = prs.data?.available ? prs.data.prs : [];
  if (list.length === 0) return null;

  return (
    <span className="relative">
      <button
        type="button"
        title={`${list.length} open pull request${list.length === 1 ? "" : "s"}`}
        onClick={(e) => {
          e.preventDefault();
          e.stopPropagation();
          setOpen((cur) => !cur);
        }}
        className="rounded bg-neutral-800 px-1.5 text-[10px] font-medium text-neutral-300 hover:bg-neutral-700"
      >
        {list.length} PR{list.length === 1 ? "" : "s"}
      </button>
      {open && (
        <div
          onClick={(e) => e.stopPropagation()}
          className="absolute top-full right-0 z-20 mt-1 max-h-80 w-72 overflow-y-auto rounded-md border border-neutral-700 bg-neutral-900 py-1 shadow-lg"
        >
          {list.map((pr) => {
            const check = CHECK_STYLE[pr.checks];
            return (
              <div key={pr.number} className="px-2 py-1.5 hover:bg-neutral-800/60">
                <div className="flex items-center gap-1.5">
                  <span
                    className={`h-1.5 w-1.5 shrink-0 rounded-full ${check.dot}`}
                    title={check.label}
                  />
                  <span className="truncate text-xs text-neutral-200" title={pr.title}>
                    <span className="text-neutral-500">#{pr.number}</span> {pr.title}
                  </span>
                  {pr.draft && (
                    <span className="shrink-0 rounded bg-neutral-700 px-1 text-[9px] text-neutral-300">
                      draft
                    </span>
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
                      setOpen(false);
                      onNewSession("claude", cwd, prPrompt(pr));
                    }}
                    className="text-neutral-300 hover:text-neutral-100"
                  >
                    ＋ session
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </span>
  );
}
