import Foundation

public enum RemoteAccessPolicy {
    static let allowedPrefixes = ["chat.", "run.", "approval."]
    static let deniedCommands: Set<String> = ["chat.delete", "run.stageForMergeTool"]
    static let allowedCommands: Set<String> = ["agent.send", "agent.perform", "agent.setModel", "settings.status", "code.readFile"]
    static let allowedFiles: Set<FileKind> = [.transcript, .specDraft, .attachment]

    public static func allows(command name: String) -> Bool {
        if deniedCommands.contains(name) { return false }
        if allowedCommands.contains(name) { return true }
        return allowedPrefixes.contains { name.hasPrefix($0) }
    }

    public static func allows(file kind: FileKind) -> Bool {
        allowedFiles.contains(kind)
    }

    static func forbidden(_ name: String) -> CommandFailure {
        CommandFailure(code: .forbidden, message: "A remote device can’t run \(name). Use Saturn on the Mac for that.")
    }
}
