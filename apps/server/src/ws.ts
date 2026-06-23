import type { Server } from "node:http";
import { WebSocketServer } from "ws";
import { sessionDb } from "./db.ts";
import { editors } from "./editor.ts";
import { registry } from "./registry.ts";
import { isProviderId } from "./providers.ts";
import { recoverCliSessionId } from "./recoverSession.ts";
import type { ClientMessage, ServerMessage } from "./protocol.ts";

export function setupWebSocket(server: Server): void {
  const wss = new WebSocketServer({ server, path: "/ws" });

  wss.on("connection", (ws) => {
    // sessionId -> cleanup functions for this connection's subscriptions.
    const subscriptions = new Map<string, () => void>();
    // Editor ptys this connection opened — killed when it disconnects so an
    // editor never outlives the tab that opened it (sessions, by design, do).
    const openedEditors = new Set<string>();

    const send = (msg: ServerMessage) => {
      if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg));
    };

    // Both real sessions and ephemeral editor ptys are addressed by id over the
    // same input/resize/kill/output/exit messages — resolve against both.
    const resolvePty = (id: string) => registry.get(id) ?? editors.get(id);

    const subscribe = (sessionId: string) => {
      if (subscriptions.has(sessionId)) return;
      const session = resolvePty(sessionId);
      if (!session) return;
      const offOutput = session.onOutput((data) => send({ type: "output", sessionId, data }));
      const offExit = session.onExit((exitCode) => send({ type: "exit", sessionId, exitCode }));
      subscriptions.set(sessionId, () => {
        offOutput();
        offExit();
      });
    };

    ws.on("message", (raw) => {
      let msg: ClientMessage;
      try {
        msg = JSON.parse(raw.toString()) as ClientMessage;
      } catch {
        send({ type: "error", message: "Invalid JSON" });
        return;
      }
      void handle(msg);
    });

    const handle = async (msg: ClientMessage): Promise<void> => {

      switch (msg.type) {
        case "create": {
          if (!isProviderId(msg.provider)) {
            send({ type: "error", message: `Unknown provider: ${msg.provider}` });
            return;
          }
          try {
            const session = registry.create(msg.provider, msg.cwd, msg.cols, msg.rows);
            if (msg.initialInput) session.autoSubmit(msg.initialInput);
            send({ type: "created", session: session.meta });
            subscribe(session.id);
            send({ type: "attached", sessionId: session.id, scrollback: "", session: session.meta });
          } catch (err) {
            send({ type: "error", message: `Failed to start ${msg.provider}: ${asMessage(err)}` });
          }
          return;
        }

        case "attach": {
          const live = registry.get(msg.sessionId);
          if (live) {
            live.resize(msg.cols, msg.rows);
            subscribe(msg.sessionId);
            send({
              type: "attached",
              sessionId: msg.sessionId,
              scrollback: live.getScrollback(),
              session: live.meta,
            });
            return;
          }
          // Not live: replay persisted history for an exited session.
          const meta = sessionDb.get(msg.sessionId);
          if (!meta) {
            send({ type: "error", sessionId: msg.sessionId, message: "Session not found" });
            return;
          }
          send({
            type: "attached",
            sessionId: msg.sessionId,
            scrollback: sessionDb.getScrollback(msg.sessionId),
            session: meta,
          });
          send({ type: "exit", sessionId: msg.sessionId, exitCode: meta.exitCode });
          return;
        }

        case "reactivate": {
          if (registry.get(msg.sessionId)) return; // already live
          const meta = sessionDb.get(msg.sessionId);
          if (!meta) {
            send({ type: "error", sessionId: msg.sessionId, message: "Session not found" });
            return;
          }
          // Old sessions predate CLI-id capture; try to recover it from the
          // CLI's own transcript so they can be resumed like newer ones.
          if (!meta.cliSessionId) {
            const recovered = await recoverCliSessionId(
              meta.provider,
              meta.cwd,
              meta.createdAt,
              sessionDb.usedCliSessionIds(),
            );
            if (recovered) {
              sessionDb.setCliSessionId(meta.id, recovered);
              meta.cliSessionId = recovered;
            }
          }
          if (!meta.cliSessionId) {
            send({
              type: "unresumable",
              sessionId: msg.sessionId,
              reason: "No prior CLI conversation could be found to resume this session.",
            });
            return;
          }
          try {
            const session = registry.resume(meta, msg.cols, msg.rows);
            subscribe(session.id);
            // Fresh pty, so start the view clean — the resumed CLI repaints its TUI.
            send({ type: "attached", sessionId: session.id, scrollback: "", session: session.meta });
          } catch (err) {
            send({
              type: "error",
              sessionId: msg.sessionId,
              message: `Failed to resume: ${asMessage(err)}`,
            });
          }
          return;
        }

        case "openEditor": {
          try {
            const ed = editors.open(msg.cwd, msg.file, msg.cols, msg.rows);
            openedEditors.add(ed.id);
            subscribe(ed.id);
            send({ type: "editorReady", editorId: ed.id });
          } catch (err) {
            send({ type: "error", message: `Failed to open editor: ${asMessage(err)}` });
          }
          return;
        }

        case "input": {
          resolvePty(msg.sessionId)?.write(msg.data);
          return;
        }

        case "resize": {
          resolvePty(msg.sessionId)?.resize(msg.cols, msg.rows);
          return;
        }

        case "kill": {
          resolvePty(msg.sessionId)?.kill();
          return;
        }

        default: {
          send({ type: "error", message: "Unknown message type" });
        }
      }
    };

    ws.on("close", () => {
      for (const cleanup of subscriptions.values()) cleanup();
      subscriptions.clear();
      // Editor ptys are tab-scoped — tear them down with the connection.
      for (const id of openedEditors) editors.get(id)?.kill();
      openedEditors.clear();
    });
  });
}

function asMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
