import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  createRootRoute,
  createRoute,
  createRouter,
  RouterProvider,
} from "@tanstack/react-router";
import { AppShell } from "./components/AppShell.tsx";
import { NewSession } from "./components/NewSession.tsx";
import { SessionView } from "./components/SessionView.tsx";
import "./styles.css";

// A 4xx (bad request, missing, 401 → handled by promptForToken) won't fix
// itself by retrying; anything else (network "Failed to fetch", 5xx, timeouts)
// is treated as transient so a backgrounded/locked phone resuming mid-request
// recovers silently instead of surfacing a hard error.
function isRetriableError(error: unknown): boolean {
  const msg = error instanceof Error ? error.message : String(error);
  return !/^4\d\d\b/.test(msg);
}

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      // Refetch the moment the network/tab is back — this is what clears any
      // error state captured while the phone was locked or backgrounded.
      refetchOnReconnect: "always",
      retry: (failureCount, error) => isRetriableError(error) && failureCount < 5,
      retryDelay: (attempt) => Math.min(1000 * 2 ** attempt, 10_000),
    },
  },
});

const rootRoute = createRootRoute({
  component: AppShell,
});

const indexRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/",
  // Optional ?cwd= lets the sidebar spawn a new chat pre-targeted at a folder.
  validateSearch: (search: Record<string, unknown>): { cwd?: string } => {
    const cwd = search.cwd;
    return typeof cwd === "string" && cwd ? { cwd } : {};
  },
  component: NewSession,
});

const sessionRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/session/$id",
  component: function SessionRoute() {
    const { id } = sessionRoute.useParams();
    return <SessionView id={id} />;
  },
});

const routeTree = rootRoute.addChildren([indexRoute, sessionRoute]);
const router = createRouter({ routeTree });

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  </StrictMode>,
);
