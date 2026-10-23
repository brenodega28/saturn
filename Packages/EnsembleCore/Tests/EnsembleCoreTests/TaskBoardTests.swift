import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct TaskBoardTests {
    typealias H = WorkflowHarness

    @Test func groupsTasksByStatusWithTheirLatestRunAndHidesDismissed() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let projectID = try #require(h.project.id)
        h.driver.script("build", .hang)
        let incoming = try h.makeTask(title: "Incoming")
        let dismissed = try h.makeTask(title: "Dismissed")
        try h.database.dismissTask(id: try #require(dismissed.id))
        let run = try h.engine.start(task: try h.makeTask(title: "Running"), workflow: try h.workflow("small-task"), project: h.project)

        let board = try h.database.taskBoard(projectId: projectID)

        #expect(board.cards.map(\.task.title).sorted() == ["Incoming", "Running"])
        #expect(board.cards(in: .incoming).map(\.task.id) == [incoming.id])
        let running = try #require(board.cards(in: .running).first)
        #expect(running.run?.id == run.id)
        #expect(running.run?.workflowDefinition?.displayName == "Small task v1")
        #expect(running.run?.workflowDefinition?.step("build")?.displayTitle == "Build")
        #expect(board.cards(in: .done).isEmpty)
        try await h.engine.cancel(try h.run(try #require(run.id)))
    }

    @Test func dismissOnlyAffectsIncomingTasks() throws {
        let h = try H.make()
        defer { h.cleanUp() }
        var task = try h.makeTask()
        task.status = .running
        try h.database.save(task)

        try h.database.dismissTask(id: try #require(task.id))

        #expect(try h.database.task(id: try #require(task.id))?.status == .running)
    }
}
