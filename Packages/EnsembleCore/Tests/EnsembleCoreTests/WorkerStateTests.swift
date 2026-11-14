import Foundation
import Testing
@testable import EnsembleCore

struct WorkerStateTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    @Test func aRunningWorkerWithRecentOutputIsWorking() {
        #expect(WorkerState.of(.init(status: .working, isRunning: true, lastOutputAt: minutesAgo(2)), now: now) == .working)
    }

    @Test func aRunningWorkerSilentPastItsLimitIsStuck() {
        #expect(WorkerState.of(.init(status: .working, isRunning: true, lastOutputAt: minutesAgo(14)), now: now) == .stuck)
        #expect(WorkerState.of(.init(status: .working, isRunning: true, lastOutputAt: minutesAgo(6), stallMinutes: 5), now: now) == .stuck)
    }

    @Test func waitingQueuedAndFinishedStatesAreKeptApart() {
        #expect(WorkerState.of(.init(status: .working, isRunning: true, needsYou: true), now: now) == .waitingOnYou)
        #expect(WorkerState.of(.init(status: .idle, isQueued: true), now: now) == .queued)
        #expect(WorkerState.of(.init(status: .idle, runFinished: true), now: now) == .done)
        #expect(WorkerState.of(.init(status: .idle), now: now) == .idle)
        #expect(WorkerState.of(.init(status: .stopped), now: now) == .stopped)
        #expect(WorkerState.of(.init(status: .failed), now: now) == .failed)
    }

    @Test func theStallLimitFollowsTheStepTimeoutUpToTenMinutes() {
        #expect(WorkerState.stallMinutes(for: nil) == 10)
        #expect(WorkerState.stallMinutes(for: WorkflowStep(id: "b", type: .agent, timeoutMinutes: 4)) == 4)
        #expect(WorkerState.stallMinutes(for: WorkflowStep(id: "b", type: .agent, timeoutMinutes: 45)) == 10)
    }
}
