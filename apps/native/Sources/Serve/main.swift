import Foundation
import JuancodeCore
import JuancodePersistence
import JuancodeServer

// Headless runner for the embedded server (juancode-u34.3): boots the real
// session registry + SQLite store + WS/HTTP server without the GUI, so apps/web
// can drive the native backend. The SwiftUI shell (u34.4) embeds the same server.

let state = try AppState()
let host = Config.bindHost

// Serve the built web app if present (apps/web/dist), resolved relative to cwd.
let webDist = (FileManager.default.currentDirectoryPath as NSString)
    .appendingPathComponent("../web/dist")

print("CorriCode serve listening on http://\(host):\(Config.port)")

try await JuancodeServer.run(
    state: state,
    host: host,
    port: Config.port,
    webDist: FileManager.default.fileExists(atPath: webDist) ? webDist : nil
)
