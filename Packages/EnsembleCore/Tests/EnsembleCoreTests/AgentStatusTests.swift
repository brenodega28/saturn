import Testing
@testable import EnsembleCore

@Suite struct AgentStatusTests {
    @Test func ordersBusiestFirst() {
        let sorted = AgentStatus.allCases.shuffled().sorted { $0.busyness < $1.busyness }
        #expect(sorted == [.needsInput, .working, .reviewing, .takenOver, .waiting, .paused, .interrupted, .failed, .stopped, .idle])
    }

    @Test func countsOnlyEngagedAgentsAsActive() {
        let active = AgentStatus.allCases.filter(\.isActive)
        #expect(Set(active) == [.needsInput, .working, .reviewing, .takenOver, .waiting])
    }
}
