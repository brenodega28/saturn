import AppKit
import CoreImage.CIFilterBuiltins
import SaturnCore
import SaturnUI
import SwiftUI

struct RemoteAccessSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var status: RemoteAccessStatus?
    @State private var portDraft = ""
    @State private var pairing: RemotePairing?
    @State private var isBusy = false

    private var workspace: DaemonWorkspace { model.local }

    var body: some View {
        SettingsPage("Remote access", subtitle: "Use Saturn from a phone or another computer on your Tailscale network. Paired devices can chat, answer questions, approve and run work, but can’t run code, write files or change keys.") {
            SettingsRows {
                HStack(spacing: 14) {
                    SettingsRowLabel(title: "Remote access", detail: summary)
                    if isBusy { ProgressView().controlSize(.small) }
                    SectionSwitch(label: "Remote access", isOn: Binding(
                        get: { status?.enabled ?? false },
                        set: { enabled in Task { await setEnabled(enabled) } }
                    ))
                    .disabled(status == nil || isBusy)
                }
                portRow
                if let status, status.enabled {
                    HStack(alignment: .top, spacing: 14) {
                        SettingsRowLabel(title: "Listening on", detail: "This Mac and its Tailscale addresses only")
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(status.addresses, id: \.self) { address in
                                Text("http://\(address):\(String(status.port))")
                                    .font(Tokens.mono(12.5))
                                    .foregroundStyle(Tokens.text)
                                    .textSelection(.enabled)
                            }
                            if !status.addresses.contains(where: RemoteAccessAddresses.isTailscale) {
                                SettingsNote("Tailscale isn’t connected, so only this Mac can reach Saturn.", color: Tokens.need)
                            }
                        }
                        .frame(width: 320, alignment: .leading)
                    }
                }
            }
            pairingCard
            SectionGroupTitle("Paired devices")
            SettingsRows {
                let devices = status?.pairedDevices ?? []
                if devices.isEmpty {
                    SettingsNote("No devices are paired.")
                }
                ForEach(devices) { device in
                    RemoteDeviceRow(device: device) {
                        Task {
                            await workspace.revokeRemoteDevice(device.id)
                            await reload()
                        }
                    }
                }
            }
        }
        .task { await reload() }
    }

    private var summary: String {
        guard let status else { return "Checking the daemon…" }
        return status.enabled ? "On. Paired devices can connect." : "Off. Nothing listens on the network."
    }

    private var portRow: some View {
        let parsed = Int(portDraft.trimmingCharacters(in: .whitespaces))
        let isValid = parsed.map { (1024...65535).contains($0) } ?? false
        return VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 14) {
                SettingsRowLabel(title: "Port", detail: "Saturn serves the web client and its connection on this port")
                TextField("Port", text: $portDraft, prompt: Text(String(RemoteAccessServer.defaultPort)))
                    .sectionField(width: 100, monospaced: true)
                    .accessibilityLabel("Remote access port")
                    .onSubmit { Task { await applyPort(parsed) } }
                Button("Apply") { Task { await applyPort(parsed) } }
                    .buttonStyle(SectionButtonStyle())
                    .disabled(!isValid || parsed == status?.port || isBusy)
            }
            if !portDraft.isEmpty, !isValid {
                SettingsNote("Use a number from 1024 to 65535.", color: Tokens.need)
            }
        }
    }

    @ViewBuilder
    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pairing {
                RemotePairingPanel(pairing: pairing, newCode: { Task { await beginPairing() } }, done: { self.pairing = nil })
            } else {
                HStack(spacing: 14) {
                    SettingsRowLabel(title: "Pair a device", detail: status?.enabled == true
                        ? "Shows a QR code and a 6-digit code that works once, for 5 minutes."
                        : "Turn on Remote access to pair a device.")
                    Button("Pair a device") { Task { await beginPairing() } }
                        .buttonStyle(SectionButtonStyle(kind: .primary))
                        .disabled(status?.enabled != true || isBusy)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionCard()
        .task(id: pairing?.code) { await watchForNewDevice() }
    }

    private func reload() async {
        status = await workspace.remoteAccessStatus()
        if let status { portDraft = String(status.port) }
    }

    private func setEnabled(_ enabled: Bool) async {
        isBusy = true
        defer { isBusy = false }
        let port = Int(portDraft.trimmingCharacters(in: .whitespaces))
        if let updated = await workspace.setRemoteAccess(enabled: enabled, port: port) { status = updated }
        if !enabled { pairing = nil }
    }

    private func applyPort(_ port: Int?) async {
        guard let port, (1024...65535).contains(port), port != status?.port else { return }
        isBusy = true
        defer { isBusy = false }
        if let updated = await workspace.setRemoteAccess(enabled: status?.enabled ?? false, port: port) { status = updated }
        pairing = nil
    }

    private func beginPairing() async {
        pairing = await workspace.beginRemotePairing()
    }

    private func watchForNewDevice() async {
        guard let pairing else { return }
        let known = Set(status?.pairedDevices.map(\.id) ?? [])
        while !Task.isCancelled, self.pairing?.code == pairing.code {
            try? await Task.sleep(for: .seconds(2))
            guard let fresh = await workspace.remoteAccessStatus() else { continue }
            status = fresh
            if fresh.pairedDevices.contains(where: { !known.contains($0.id) }) {
                self.pairing = nil
                return
            }
        }
    }
}

private struct RemotePairingPanel: View {
    let pairing: RemotePairing
    let newCode: () -> Void
    let done: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(pairing.expiresAt.timeIntervalSince(context.date).rounded(.up)))
            HStack(alignment: .top, spacing: 18) {
                QRCodeImage(text: pairing.url)
                    .frame(width: 168, height: 168)
                    .opacity(remaining == 0 ? 0.25 : 1)
                    .accessibilityLabel("QR code for \(pairing.url)")
                VStack(alignment: .leading, spacing: 10) {
                    Text("Scan with the phone’s camera, or open this address, then enter the code.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Tokens.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(pairing.url)
                        .font(Tokens.mono(12.5))
                        .foregroundStyle(Tokens.text)
                        .textSelection(.enabled)
                    Text(Self.spaced(pairing.code))
                        .font(Tokens.mono(30, weight: .semibold))
                        .foregroundStyle(remaining == 0 ? Tokens.text3 : Tokens.text)
                        .textSelection(.enabled)
                        .accessibilityLabel("Pairing code \(pairing.code.map(String.init).joined(separator: " "))")
                    Text(remaining == 0 ? "This code expired." : "Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                        .font(.system(size: 12))
                        .foregroundStyle(remaining == 0 ? Tokens.need : Tokens.text2)
                        .monospacedDigit()
                    HStack(spacing: 8) {
                        Button("New code", action: newCode).buttonStyle(SectionButtonStyle())
                        Button("Done", action: done).buttonStyle(SectionButtonStyle())
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    static func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}

private struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .padding(8)
                .background(.white, in: .rect(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tokens.fill)
        }
    }

    static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

private struct RemoteDeviceRow: View {
    let device: RemoteDevice
    let revoke: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: Self.symbol(for: device.name))
                .font(.system(size: 16))
                .foregroundStyle(Tokens.text2)
                .frame(width: 22)
                .accessibilityHidden(true)
            SettingsRowLabel(title: device.name, detail: detail)
            Button("Revoke", role: .destructive, action: revoke)
                .buttonStyle(SectionButtonStyle())
                .help("Signs this device out and closes its connection")
        }
    }

    private var detail: String {
        let paired = "Paired \(device.createdAt.formatted(date: .abbreviated, time: .shortened))"
        guard let seen = device.lastSeenAt else { return paired + " · Not connected yet" }
        return paired + " · Last seen \(seen.formatted(.relative(presentation: .named)))"
    }

    static func symbol(for name: String) -> String {
        switch name {
        case "iPhone", "Android": "iphone"
        case "iPad": "ipad"
        case "Mac": "laptopcomputer"
        default: "globe"
        }
    }
}
