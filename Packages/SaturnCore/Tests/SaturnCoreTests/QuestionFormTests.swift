import Foundation
import Testing
@testable import SaturnCore

@Suite struct QuestionFormTests {
    let numbered = """
    Before I plan the architect app changes, I need a few decisions:

    1. Identity: keep inheritance (smaller change) or switch to an explicit OneToOneField?
    This changes how the serializer creates users.
    2. New Architect fields: should is_public filter the public list?
    3. PortfolioProject: Options: (a) keep pictures and add nothing, treating dbml as incomplete; (b) replace pictures with a single image_url; (c) keep both. Which one?
    """

    @Test func numberedQuestionsBecomeSteps() {
        let form = QuestionForm.parse(numbered)
        #expect(form.intro == "Before I plan the architect app changes, I need a few decisions:")
        #expect(form.questions.map(\.question) == [
            "Identity: keep inheritance (smaller change) or switch to an explicit OneToOneField?\nThis changes how the serializer creates users.",
            "New Architect fields: should is_public filter the public list?",
            "PortfolioProject: Options: (a) keep pictures and add nothing, treating dbml as incomplete; (b) replace pictures with a single image_url; (c) keep both. Which one?",
        ])
        #expect(form.isMultiStep)
    }

    @Test func letteredChoicesBecomeOptions() {
        let form = QuestionForm.parse(numbered)
        #expect(form.questions[0].options.isEmpty)
        #expect(form.questions[2].options == [
            "keep pictures and add nothing, treating dbml as incomplete",
            "replace pictures with a single image_url",
            "keep both",
        ])
        #expect(QuestionForm.letteredOptions(in: "Pick (a) one only.") == [])
        #expect(QuestionForm.letteredOptions(in: "Either (b) this or (c) that") == [])
    }

    @Test func plainTextIsOneQuestion() {
        let form = QuestionForm.parse("Postgres or SQLite?")
        #expect(form.questions == [HumanQuestion(question: "Postgres or SQLite?")])
        #expect(!form.isMultiStep)
        #expect(form.reply(["SQLite"]) == "SQLite")
    }

    @Test func numbersOutOfSequenceStayInTheQuestion() {
        let form = QuestionForm.parse("Context\n2. not a list\n3. still not")
        #expect(form.questions.count == 1)
    }

    @Test func repliesAreNumberedAndSkippedOnesSaySo() {
        let form = QuestionForm.parse(numbered)
        #expect(form.reply(["Keep inheritance", "  ", "keep both — drop the timestamps"]) == """
        1. Keep inheritance
        2. \(QuestionForm.skippedAnswer)
        3. keep both — drop the timestamps
        """)
    }

    @Test func structuredQuestionsWinOverTheBody() {
        let item = ChatRequest(
            projectId: 1, kind: .question, title: "Lead asks", body: "Two decisions for the API.",
            questions: [HumanQuestion(question: "REST or GraphQL?", options: ["REST", "GraphQL"]), HumanQuestion(question: "Version the URLs?")],
            createdAt: .now
        )
        let form = QuestionForm(item: item)
        #expect(form.intro == "Two decisions for the API.")
        #expect(form.questions.map(\.options) == [["REST", "GraphQL"], []])
    }

    @Test func askHumanAcceptsAQuestionList() throws {
        let message = try HandoffTool.askHuman.decode(.object([
            "question": .string("Two decisions"),
            "questions": .array([
                .object(["question": .string("REST or GraphQL?"), "options": .array([.string("REST"), .string("GraphQL")])]),
                .object(["question": .string("  ")]),
                .object(["question": .string("Version the URLs?")]),
            ]),
        ]))
        #expect(message == .question("Two decisions", [
            HumanQuestion(question: "REST or GraphQL?", options: ["REST", "GraphQL"]),
            HumanQuestion(question: "Version the URLs?"),
        ]))
    }

    @Test func questionListsSurviveTheDatabase() throws {
        let database = try AppDatabase.inMemory()
        let project = try database.openProject(at: URL(fileURLWithPath: "/tmp/shop"))
        let questions = [HumanQuestion(question: "REST or GraphQL?", options: ["REST", "GraphQL"])]
        let item = try database.createChatRequest(ChatRequest(projectId: try #require(project.id), kind: .question, title: "Lead asks", questions: questions, createdAt: .now))
        #expect(try database.chatRequest(id: try #require(item.id))?.questions == questions)
    }
}
