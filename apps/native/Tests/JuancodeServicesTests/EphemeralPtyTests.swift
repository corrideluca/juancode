import XCTest
@testable import JuancodeServices

final class EphemeralPtyTests: XCTestCase {
    func testEditorCommandDefaultsToNvim() {
        XCTAssertEqual(editorCommand(env: [:]).cmd, "nvim")
        XCTAssertTrue(editorCommand(env: [:]).args.isEmpty)
    }

    func testEditorCommandSplitsArgs() {
        let (cmd, args) = editorCommand(env: ["VISUAL": "code -w"])
        XCTAssertEqual(cmd, "code")
        XCTAssertEqual(args, ["-w"])
    }

    func testEditorCommandPrefersVisualOverEditor() {
        XCTAssertEqual(editorCommand(env: ["VISUAL": "vim", "EDITOR": "nano"]).cmd, "vim")
        XCTAssertEqual(editorCommand(env: ["EDITOR": "nano"]).cmd, "nano")
    }

    func testShellCommandDefaultsToZshInteractive() {
        let (cmd, args) = shellCommand(env: [:])
        XCTAssertEqual(cmd, "/bin/zsh")
        XCTAssertEqual(args, ["-i"])
    }

    func testShellCommandHonoursShellEnv() {
        XCTAssertEqual(shellCommand(env: ["SHELL": "/bin/bash"]).cmd, "/bin/bash")
    }

    func testOpenEditorRejectsPathOutsideCwd() {
        let reg = EphemeralPtyRegistry()
        XCTAssertThrowsError(try reg.openEditor(cwd: "/tmp", file: "../etc/passwd", cols: 80, rows: 24)) { err in
            XCTAssertEqual(err as? EphemeralPtyError, .outsideWorkingDir)
        }
    }
}

extension EphemeralPtyError: Equatable {
    public static func == (lhs: EphemeralPtyError, rhs: EphemeralPtyError) -> Bool {
        String(describing: lhs) == String(describing: rhs)
    }
}
