import Foundation
import SaturnCore

extension DaemonWorkspace {
    func remoteAccessStatus() async -> RemoteAccessStatus? {
        try? await send(RemoteAccessCommands.Status())
    }

    func setRemoteAccess(enabled: Bool, port: Int? = nil) async -> RemoteAccessStatus? {
        await command(enabled ? "Couldn’t turn on Remote access" : "Couldn’t turn off Remote access", RemoteAccessCommands.SetEnabled(enabled: enabled, port: port))
    }

    func beginRemotePairing() async -> RemotePairing? {
        await command("Couldn’t start pairing", RemoteAccessCommands.BeginPairing())
    }

    func revokeRemoteDevice(_ deviceID: UUID) async {
        await command("Couldn’t revoke the device", RemoteAccessCommands.Revoke(deviceID: deviceID))
    }
}
