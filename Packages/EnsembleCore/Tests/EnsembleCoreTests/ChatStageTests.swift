import Foundation
import Testing
@testable import EnsembleCore

struct ChatStageTests {
    typealias Facts = ChatStage.Facts

    func run(_ status: RunStatus) -> Run {
        Run(id: 1, projectId: 1, taskId: 1, workflow: "w", status: status, startedAt: .now)
    }

    func hold(_ reason: HoldReason) -> RunHold {
        RunHold(reason: reason, stepId: "s", message: "m")
    }

    @Test func closedChatsAreResolvedOrClosed() {
        #expect(ChatStage.of(Facts(closeReason: .done, isClosed: true, hold: hold(.approval))) == .done)
        #expect(ChatStage.of(Facts(closeReason: .dropped, isClosed: true)) == .dropped)
    }

    @Test func failuresAndLimitsAreStuck() {
        #expect(ChatStage.of(Facts(latestRun: run(.waitingOnYou), hold: hold(.stepFailed))) == .stuck)
        #expect(ChatStage.of(Facts(latestRun: run(.waitingOnYou), hold: hold(.runBudget))) == .stuck)
        #expect(ChatStage.of(Facts(latestRun: run(.failed))) == .stuck)
        #expect(ChatStage.of(Facts(openRequests: [.budget])) == .stuck)
    }

    @Test func approvalsQuestionsPermissionsAndSpecsNeedYou() {
        #expect(ChatStage.of(Facts(latestRun: run(.waitingOnYou), hold: hold(.planApproval))) == .needsYou)
        #expect(ChatStage.of(Facts(latestRun: run(.waitingOnYou), hold: hold(.gates))) == .needsYou)
        #expect(ChatStage.of(Facts(openRequests: [.question])) == .needsYou)
        #expect(ChatStage.of(Facts(pendingPermissions: 1)) == .needsYou)
        #expect(ChatStage.of(Facts(hasOpenProposal: true)) == .needsYou)
        #expect(ChatStage.of(Facts(openRequests: [.notice])) == .idle)
    }

    @Test func theFinalApprovalAndReviewStepsAreInReview() {
        #expect(ChatStage.of(Facts(latestRun: run(.waitingOnYou), hold: hold(.approval))) == .inReview)
        let review = WorkflowStep(id: "review", type: .agent, agent: .checker)
        #expect(ChatStage.of(Facts(latestRun: run(.running), currentStep: review)) == .inReview)
        #expect(ChatStage.of(Facts(latestRun: run(.running), currentStep: WorkflowStep(id: "gates", type: .gates))) == .inReview)
    }

    @Test func finishedRanksBelowClosedAndAttentionStates() {
        #expect(ChatStage.of(Facts(closeReason: .done, isClosed: true, isFinished: true)) == .done)
        #expect(ChatStage.of(Facts(isFinished: true, latestRun: run(.failed))) == .stuck)
        #expect(ChatStage.of(Facts(isFinished: true, openRequests: [.question])) == .needsYou)
        #expect(ChatStage.of(Facts(isFinished: true, latestRun: run(.waitingOnYou), hold: hold(.approval))) == .inReview)
        #expect(ChatStage.of(Facts(isFinished: true, leadIsWorking: true)) == .building)
        #expect(ChatStage.of(Facts(isFinished: true, latestRun: run(.cancelled))) == .finished)
    }

    @Test func runningWorkOrAWorkingLeadIsBuilding() {
        let build = WorkflowStep(id: "build", type: .agent, agent: .builder)
        #expect(ChatStage.of(Facts(latestRun: run(.running), currentStep: build)) == .building)
        #expect(ChatStage.of(Facts(leadIsWorking: true)) == .building)
    }

    @Test func aSucceededRunOrAFinishedChatIsFinishedAndAQuietChatIsIdle() {
        #expect(ChatStage.of(Facts(latestRun: run(.succeeded))) == .finished)
        #expect(ChatStage.of(Facts(isFinished: true)) == .finished)
        #expect(ChatStage.of(Facts()) == .idle)
        #expect(ChatStage.needsYou.needsAttention && ChatStage.stuck.needsAttention && !ChatStage.building.needsAttention)
    }
}
