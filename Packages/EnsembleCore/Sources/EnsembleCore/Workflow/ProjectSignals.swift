import Foundation

public enum ProjectSignals {
    public static let activeStatuses: Set<RunStatus> = [.pending, .running, .waitingOnYou, .paused, .interrupted]

    public static func output(of step: RunStep) -> StepOutput? {
        step.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }
    }
}
