import EnsembleCore
import EnsembleUI
import SwiftUI

struct ServersSettings: View {
    @Environment(AppModel.self) private var model
    @State private var destination = ""

    var body: some View {
        SettingsPane {
            Text("Each server runs its own Ensemble daemon, so its runs keep going while this Mac sleeps or is off.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.orderedConnections) { connection in
                ServerRow(connection: connection)
            }
            ForEach(model.knownDaemons.filter { known in model.connections[known.id] == nil }) { known in
                Text("\(known.displayName): connecting…").font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
            }
            Divider()
            Text("Add a server").font(.system(size: 13, weight: .semibold))
            HStack {
                TextField("user@host", text: $destination)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .accessibilityLabel("SSH destination of the server")
                Button("Add Server", action: add)
                    .disabled(destination.trimmingCharacters(in: .whitespaces).isEmpty || !model.addingServers.isEmpty)
                if !model.addingServers.isEmpty { ProgressView().controlSize(.small) }
            }
            Text("Ensemble signs in with your SSH keys, copies its daemon to ~/.ensemble/bin and runs it as a LaunchAgent for the user who is logged in at the server. It never needs sudo.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func add() {
        let input = destination
        Task {
            if await model.addServer(input) != nil { destination = "" }
        }
    }
}

private struct ServerRow: View {
    @Environment(AppModel.self) private var model
    let connection: DaemonConnection

    var body: some View {
        let live = connection.live
        let environment = live.environment
        let problem = connection.destination.flatMap { model.serverProblems[$0] }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: connection.isRemote ? "server.rack" : "laptopcomputer").foregroundStyle(Theme.secondaryText)
                Text(model.displayName(of: connection)).font(.system(size: 13, weight: .semibold))
                Text(stateText).font(.system(size: 11.5)).foregroundStyle(stateColor)
                Spacer()
                if connection.id == model.connection.id {
                    Text("Showing").font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
                } else {
                    Button("Show") { model.activate(connection.id) }
                }
                if connection.isRemote {
                    Menu("More") {
                        Button("Upgrade Daemon") { Task { await model.upgradeServer(connection) } }
                        Button("Stop Daemon") { model.stopServerDaemon(connection) }
                        Button("Remove Server", role: .destructive) { model.removeServer(connection) }
                    }
                    .fixedSize()
                }
            }
            Group {
                Text("Version \(connection.client.buildVersion ?? "unknown") · \(live.activeRunCount) active run\(live.activeRunCount == 1 ? "" : "s") · \(live.agents.values.filter(\.isRunning).count) running agent\(live.agents.values.filter(\.isRunning).count == 1 ? "" : "s")")
                Text(environment.loginSummary).foregroundStyle(environment.isLoginReady ? Theme.secondaryText : Theme.warning)
                if let claude = environment.claudeProblem { Text(claude).foregroundStyle(Theme.warning) }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)
            if connection.isRemote, environment.fileVaultOn == true {
                Label(
                    "FileVault is on, so after a restart this server waits for someone to unlock it at its screen before the daemon can start. For planned restarts, run sudo fdesetup authrestart on the server.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem.message).font(.system(size: 11.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                if problem.runsActive != nil {
                    Button("Upgrade Anyway") { Task { await model.upgradeServer(connection) } }
                }
            }
        }
        .padding(10)
        .background(Theme.fill, in: .rect(cornerRadius: 10, style: .continuous))
    }

    private var stateText: String {
        switch connection.state {
        case .connected: "Connected"
        case .connecting, .syncing: "Connecting…"
        case .idle: "Not connected"
        case .disconnected: "Offline · retrying"
        case .refused(let message, _): message
        }
    }

    private var stateColor: Color {
        switch connection.state {
        case .connected: Theme.successText
        case .refused: Theme.danger
        default: Theme.secondaryText
        }
    }
}
