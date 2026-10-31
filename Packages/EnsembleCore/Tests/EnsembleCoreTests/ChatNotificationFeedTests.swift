import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct ChatNotificationFeedTests {
    let launch = Date(timeIntervalSince1970: 1_800_000_000)

    func at(_ minutes: Double) -> Date {
        launch.addingTimeInterval(minutes * 60)
    }

    func message(_ id: Int64, _ kind: LeadMessageKind, minutes: Double, text: String = "Hello", title: String? = nil) -> LeadMessage {
        LeadMessage(id: id, projectId: 1, taskId: 7, kind: kind, text: text, title: title, createdAt: at(minutes))
    }

    func run(_ id: Int64, _ status: RunStatus, endedMinutes: Double?, title: String = "Ship it") -> Run {
        Run(id: id, projectId: 1, taskId: 7, workflow: "feature-delivery", status: status, startedAt: at(-30), endedAt: endedMinutes.map(at), title: title)
    }

    func collect(_ feed: ChatNotificationFeed) -> () -> [ChatNotification] {
        final class Box { var items: [ChatNotification] = [] }
        let box = Box()
        feed.onNew = { box.items += $0 }
        return { box.items }
    }

    @Test func detectsAllFourEvents() throws {
        let feed = ChatNotificationFeed(database: try AppDatabase.inMemory(), launchedAt: launch)
        let notified = collect(feed)
        let longReply = String(repeating: "word ", count: 60)

        feed.receive(
            messages: [
                message(1, .permission, minutes: 1, text: "git push origin main", title: "Builder 2"),
                message(2, .proposal, minutes: 2, text: "Build the feed", title: "Notify for chat events"),
                message(3, .lead, minutes: 3, text: longReply),
                message(4, .user, minutes: 4),
                message(5, .note, minutes: 5),
            ],
            runs: [run(10, .succeeded, endedMinutes: 6), run(11, .failed, endedMinutes: 7), run(12, .cancelled, endedMinutes: 8)]
        )

        let items = notified()
        #expect(items.map(\.event) == [.permissionCard, .runProposal, .leadReply, .runFinished, .runFinished, .runFinished])
        #expect(items[0].title.contains("Builder 2"))
        #expect(items[0].body == "git push origin main")
        #expect(items[1].title.contains("Notify for chat events"))
        #expect(items[2].body.count <= ChatNotification.excerptLength + 1)
        #expect(longReply.hasPrefix(String(items[2].body.dropLast())))
        #expect(items[2].body.hasSuffix("…"))
        #expect(items[3].title == "Ship it")
        #expect(items.dropFirst(3).map(\.body) == ["Run succeeded", "Run failed", "Run cancelled"])
        #expect(items.allSatisfy { $0.projectId == 1 && $0.taskId == 7 })
        #expect(Set(items.map(\.dedupeKey)).count == items.count)
    }

    @Test func ignoresRunsThatAreNotFinished() throws {
        let feed = ChatNotificationFeed(database: try AppDatabase.inMemory(), launchedAt: launch)
        let notified = collect(feed)

        feed.receive(messages: [], runs: [
            run(1, .running, endedMinutes: nil),
            run(2, .interrupted, endedMinutes: 1),
            run(3, .paused, endedMinutes: 1),
            run(4, .waitingOnYou, endedMinutes: nil),
            run(5, .succeeded, endedMinutes: nil),
        ])

        #expect(notified().isEmpty)
    }

    @Test func ignoresEventsFromBeforeLaunch() throws {
        let feed = ChatNotificationFeed(database: try AppDatabase.inMemory(), launchedAt: launch)
        let notified = collect(feed)

        feed.receive(
            messages: [message(1, .lead, minutes: -1), message(2, .permission, minutes: 1, title: "Ada")],
            runs: [run(1, .succeeded, endedMinutes: -1), run(2, .failed, endedMinutes: 2)]
        )

        #expect(notified().map(\.dedupeKey) == ["lead-message-2", "run-2"])
    }

    @Test func dedupesAcrossRepeatedReceives() throws {
        let feed = ChatNotificationFeed(database: try AppDatabase.inMemory(), launchedAt: launch)
        let notified = collect(feed)
        let first = message(1, .proposal, minutes: 1, title: "Plan")
        let finished = run(1, .succeeded, endedMinutes: 2)

        feed.receive(messages: [first], runs: [finished])
        feed.receive(messages: [first], runs: [finished])
        feed.receive(messages: [first, message(2, .lead, minutes: 3)], runs: [finished])
        feed.receive(messages: [], runs: [run(1, .succeeded, endedMinutes: 2)])

        #expect(notified().map(\.dedupeKey) == ["lead-message-1", "run-1", "lead-message-2"])
    }

    @Test func messageAndRunWithTheSameIdBothNotify() throws {
        let feed = ChatNotificationFeed(database: try AppDatabase.inMemory(), launchedAt: launch)
        let notified = collect(feed)

        feed.receive(messages: [message(5, .lead, minutes: 1)], runs: [run(5, .failed, endedMinutes: 1)])

        #expect(notified().map(\.event) == [.leadReply, .runFinished])
    }

    @Test func liveFeedReportsNewRowsOnce() async throws {
        let database = try AppDatabase.inMemory()
        let project = try database.openProject(at: URL(fileURLWithPath: "/tmp/chat-notify-\(UUID().uuidString)"))
        let projectId = try #require(project.id)
        let task = try database.insert(ProjectTask(projectId: projectId, title: "T", body: "", source: .chat, status: .incoming, createdAt: at(-60), updatedAt: at(-60)))
        let taskId = try #require(task.id)
        try database.insert(LeadMessage(projectId: projectId, taskId: taskId, kind: .lead, text: "Old", createdAt: at(-5)))

        let feed = ChatNotificationFeed(database: database, launchedAt: launch)
        let notified = collect(feed)
        feed.start()
        #expect(notified().isEmpty)

        try database.insert(LeadMessage(projectId: projectId, taskId: taskId, kind: .user, text: "Hi", createdAt: at(1)))
        try database.insert(LeadMessage(projectId: projectId, taskId: taskId, kind: .lead, text: "Hello back", createdAt: at(2)))
        try await waitUntil { notified().count == 1 }
        #expect(notified().first?.event == .leadReply)
        #expect(notified().first?.body == "Hello back")

        let running = Run(projectId: projectId, taskId: taskId, workflow: "feature-delivery", status: .running, startedAt: at(1), title: "Deliver")
        var row = try await database.writer.write { db in try running.inserted(db) }
        row.status = .succeeded
        row.endedAt = at(3)
        let finished = row
        try await database.writer.write { db in try finished.update(db) }
        try await waitUntil { notified().count == 2 }
        #expect(notified().last?.event == .runFinished)
        #expect(notified().last?.title == "Deliver")

        try database.insert(LeadMessage(projectId: projectId, taskId: taskId, kind: .note, text: "Note", createdAt: at(4)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(notified().count == 2)
        feed.stop()
    }

    @Test(arguments: [
        NotificationTarget.chat(projectId: 3, taskId: 9),
        NotificationTarget.inboxItem(id: 42),
    ])
    func targetRoundTripsThroughUserInfo(target: NotificationTarget) {
        #expect(NotificationTarget(userInfo: target.userInfo) == target)
    }

    @Test func targetDecodesBridgedNumbersAndRejectsGarbage() {
        let bridged: [AnyHashable: Any] = ["target": "chat", "projectId": NSNumber(value: 3), "taskId": 9]
        #expect(NotificationTarget(userInfo: bridged) == .chat(projectId: 3, taskId: 9))
        #expect(NotificationTarget(userInfo: [:]) == nil)
        #expect(NotificationTarget(userInfo: ["target": "chat", "projectId": 3]) == nil)
        #expect(NotificationTarget(userInfo: ["target": "inboxItem"]) == nil)
        #expect(NotificationTarget(userInfo: ["target": "other", "inboxItemId": 1]) == nil)
    }

    @Test func suppressionTruthTable() {
        let visible: (projectId: Int64, taskId: Int64) = (1, 7)
        let cases: [(appActive: Bool, visible: (projectId: Int64, taskId: Int64)?, target: (projectId: Int64, taskId: Int64?), suppressed: Bool)] = [
            (true, visible, (1, 7), true),
            (false, visible, (1, 7), false),
            (true, nil, (1, 7), false),
            (true, visible, (1, 8), false),
            (true, visible, (2, 7), false),
            (true, visible, (1, nil), false),
            (false, nil, (1, nil), false),
        ]
        for entry in cases {
            #expect(NotificationSuppression.shouldSuppress(appActive: entry.appActive, visibleChat: entry.visible, target: entry.target) == entry.suppressed)
        }
    }
}
