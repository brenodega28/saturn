import Foundation
import Testing
@testable import SaturnCore

struct SystemAlertTests {
    let local = Project(id: 1, name: "shopfront", path: "/tmp/shop", isOpen: true, createdAt: .now, lastOpenedAt: .now)
    let remote = Project(id: 2, name: "billing-service", path: "/srv/billing", host: "devbox-02", isOpen: true, createdAt: .now, lastOpenedAt: .now)

    func report(_ claude: ToolCheck) -> EnvironmentReport {
        EnvironmentReport(git: .found(path: URL(fileURLWithPath: "/usr/bin/git"), version: "2.47"), claude: claude, provider: .claudeSignIn(account: nil, isSignedIn: true))
    }

    @Test func aHealthySetupHasNoAlerts() {
        let alerts = SystemAlert.detect(
            environment: report(.found(path: URL(fileURLWithPath: "/opt/homebrew/bin/claude"), version: "2.1.14")),
            planUsage: PlanUsage(session: PlanUsageWindow(utilization: 42)), projects: [local, remote], remoteErrors: [:]
        )
        #expect(alerts.isEmpty)
    }

    @Test func aMissingCLIARateLimitAndAnOfflineHostAreAlerts() {
        let resets = Date(timeIntervalSince1970: 1_800_000_000)
        let alerts = SystemAlert.detect(
            environment: report(.missing), planUsage: PlanUsage(session: PlanUsageWindow(utilization: 100, resetsAt: resets)),
            projects: [local, remote], remoteErrors: [2: "ssh: connect timed out", 1: "ignored for local projects"]
        )
        #expect(alerts == [.claudeMissing, .rateLimited(resetsAt: resets), .hostDisconnected(projectID: 2, host: remote.location, projectName: "billing-service", error: "ssh: connect timed out")])
        #expect(alerts[2].affects(remote) && !alerts[2].affects(local))
        #expect(alerts[0].affects(local))
    }
}
