import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// Where `pnpm dev:web` proxies `/api` + `/ws`. The same wire protocol is spoken
// by the Node server (`apps/server`) and the Mac app's embedded server
// (`apps/native`, juancode-serve) — both default to :4280 — so this one web app
// is a remote client for either backend. Override `JUANCODE_SERVER` to point dev
// at an embedded server on another host (e.g. `http://my-mac.local:4280`), or set
// `JUANCODE_PORT` to match a server bound to a non-default port. In production the
// embedded server serves the built `apps/web/dist` itself, so no proxy runs.
const SERVER =
  process.env.JUANCODE_SERVER ?? `http://localhost:${process.env.JUANCODE_PORT ?? "4280"}`;

export default defineConfig({
  plugins: [react(), tailwindcss()],
  define: {
    // refractor@2 (CommonJS) references Node's `global`, absent in the browser
    global: "globalThis",
  },
  server: {
    port: 5280,
    open: true,
    proxy: {
      "/api": { target: SERVER, changeOrigin: true },
      "/ws": { target: SERVER, ws: true, changeOrigin: true },
    },
  },
});
