import Foundation
import Synchronization
import Testing
@testable import SaturnCore

final class TestClock: Sendable {
    private let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    var now: Date { time.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        time.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

@Suite struct RemoteAccessPairingTests {
    @Test func aCodeIsSixDigitsAndWorksOnce() {
        let clock = TestClock()
        let pairing = RemoteAccessPairing { clock.now }
        let (code, expiresAt) = pairing.begin()
        #expect(code.count == 6 && code.allSatisfy(\.isNumber))
        #expect(expiresAt == clock.now.addingTimeInterval(300))
        #expect(pairing.redeem(code))
        #expect(!pairing.redeem(code))
    }

    @Test func aCodeExpiresAfterFiveMinutes() {
        let clock = TestClock()
        let pairing = RemoteAccessPairing { clock.now }
        let (code, _) = pairing.begin()
        clock.advance(300)
        #expect(!pairing.redeem(code))
    }

    @Test func aCodeIsStillValidJustBeforeItExpires() {
        let clock = TestClock()
        let pairing = RemoteAccessPairing { clock.now }
        let (code, _) = pairing.begin()
        clock.advance(299)
        #expect(pairing.redeem(code))
    }

    @Test func fiveWrongGuessesBurnTheCode() {
        let pairing = RemoteAccessPairing()
        let (code, _) = pairing.begin()
        let wrong = code == "000000" ? "111111" : "000000"
        for _ in 0..<5 { #expect(!pairing.redeem(wrong)) }
        #expect(!pairing.redeem(code))
    }

    @Test func nothingRedeemsBeforePairingBegins() {
        #expect(!RemoteAccessPairing().redeem("123456"))
    }

    @Test func devicesStoreOnlyTokenHashesInAPrivateFile() throws {
        let directory = DaemonTestPaths.shortDirectory("rd")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = AppPaths(root: directory).remoteDevices
        #expect(url.lastPathComponent == "remote-devices.json")
        let clock = TestClock()
        let devices = RemoteAccessDevices(url: url) { clock.now }
        let (token, device) = try devices.add(name: "iPhone")

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains(token))
        #expect(text.contains(RemoteAccessDevices.hash(token)))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.int16Value == 0o600)

        clock.advance(60)
        #expect(devices.authenticate(token)?.id == device.id)
        #expect(devices.authenticate("wrong") == nil)
        let reloaded = RemoteAccessDevices(url: url)
        #expect(reloaded.all.map(\.id) == [device.id])
        #expect(reloaded.all.first?.lastSeenAt == clock.now)
        #expect(reloaded.all.first?.name == "iPhone")

        #expect(try reloaded.remove(device.id))
        #expect(reloaded.authenticate(token) == nil)
        #expect(RemoteAccessDevices(url: url).all.isEmpty)
    }

    @Test func allowlistMatchesTheSpec() {
        for name in ["chat.send", "chat.approveSpec", "run.merge", "run.push", "approval.answerQuestion", "approval.answerPermission",
                     "agent.send", "agent.perform", "agent.setModel", "settings.status", "code.readFile"] {
            #expect(RemoteAccessPolicy.allows(command: name), "\(name)")
        }
        for name in ["chat.delete", "run.stageForMergeTool", "code.exec", "code.writeFile", "code.removeItem", "code.git",
                     "settings.saveAPIKey", "settings.shutdown", "settings.get", "agent.delete", "agent.spawn", "project.open",
                     "remote.status", "remote.setEnabled", "remote.beginPairing", "remote.revoke", "chatty", ""] {
            #expect(!RemoteAccessPolicy.allows(command: name), "\(name)")
        }
        #expect(RemoteAccessPolicy.allows(file: .transcript))
        #expect(RemoteAccessPolicy.allows(file: .specDraft))
        #expect(RemoteAccessPolicy.allows(file: .attachment))
        #expect(!RemoteAccessPolicy.allows(file: .agentFile))
        #expect(!RemoteAccessPolicy.allows(file: .evidence))
    }

    @Test func tailscaleRangeIsOneHundredSixtyFourSlashTen() {
        #expect(RemoteAccessAddresses.isTailscale("100.64.0.1"))
        #expect(RemoteAccessAddresses.isTailscale("100.127.255.254"))
        #expect(!RemoteAccessAddresses.isTailscale("100.63.0.1"))
        #expect(!RemoteAccessAddresses.isTailscale("100.128.0.1"))
        #expect(!RemoteAccessAddresses.isTailscale("10.0.0.1"))
        #expect(!RemoteAccessAddresses.isAllowed("0.0.0.0"))
        #expect(RemoteAccessAddresses.tailscale().allSatisfy(RemoteAccessAddresses.isTailscale))
    }

    @Test func deviceNamesComeFromTheUserAgent() {
        #expect(RemoteAccessGateway.deviceName(userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)") == "iPhone")
        #expect(RemoteAccessGateway.deviceName(userAgent: nil) == "Browser")
    }
}
