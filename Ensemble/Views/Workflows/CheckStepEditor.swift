import EnsembleCore
import EnsembleUI
import SwiftUI

struct CheckStepEditor: View {
    @Binding var step: WorkflowStep
    let checks: [CheckDefinition]

    var body: some View {
        InspectorField("Checks to run") {
            if checks.isEmpty {
                Text("No checks yet. Add them in Settings › Checks or in \(ProjectConfig.directoryName)/\(ChecksConfig.fileName).")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(checks) { check in
                        Toggle(isOn: binding(for: check)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(check.name).font(.system(size: 12.5, weight: .medium))
                                Text(check.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
        InspectorField("Rounds") {
            VStack(alignment: .leading, spacing: 8) {
                Stepper(value: Binding(get: { step.maxRounds ?? ChecksConfig.defaultMaxRounds }, set: { step.maxRounds = $0 }), in: 1...10) {
                    Text("Up to \(step.maxRounds ?? ChecksConfig.defaultMaxRounds) rounds, then you decide in the chat").font(.system(size: 12.5))
                }
                .help("How many times checks run before failing work comes to you")
                Toggle("Test first", isOn: $step.testFirst)
                    .help("Builders commit a failing test before the fix; Ensemble checks it fails without the fix")
            }
        }
    }

    private func binding(for check: CheckDefinition) -> Binding<Bool> {
        Binding(
            get: { step.checks?.contains(check.name) ?? true },
            set: { isOn in
                var selected = step.checks ?? checks.map(\.name)
                if isOn {
                    if !selected.contains(check.name) { selected.append(check.name) }
                } else {
                    selected.removeAll { $0 == check.name }
                }
                let ordered = checks.map(\.name).filter(selected.contains)
                step.checks = ordered.count == checks.count ? nil : ordered
            }
        )
    }
}
