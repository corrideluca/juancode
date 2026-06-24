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

const queryClient = new QueryClient();

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
