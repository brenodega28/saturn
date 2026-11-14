import EnsembleCore
import EnsembleUI
import SwiftUI

struct ChatSettingsView: View {
    static let holdChoices = [0, 1, 2, 3, 5, 10]

    @AppStorage(AppModel.sendHoldSecondsKey) private var holdSeconds = AppModel.defaultSendHoldSeconds

    var body: some View {
        SettingsPage("Chat", subtitle: "Applies to every project and every chat with the Lead.") {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hold sent messages for").font(.system(size: 13.5, weight: .semibold))
                    Text(holdSeconds == 0
                         ? "Messages go to the agent as soon as you send them."
                         : "Each message waits \(holdSeconds)s before it reaches the agent, so you can press Undo or Esc to take it back.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker("Hold sent messages for", selection: $holdSeconds) {
                    ForEach(choices, id: \.self) { seconds in
                        Text(seconds == 0 ? "Off" : "\(seconds) seconds").tag(seconds)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("How long a sent message waits before it reaches the agent")
            }
            .padding(16)
            .card(cornerRadius: 16)
        }
    }

    private var choices: [Int] {
        Self.holdChoices.contains(holdSeconds) ? Self.holdChoices : (Self.holdChoices + [holdSeconds]).sorted()
    }
}
