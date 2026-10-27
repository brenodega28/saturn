import Foundation
@testable import EnsembleCore

enum LegacyWorkflows {
    static let featureDelivery = """
    name: Feature delivery
    version: 1
    description: The lead plans, developers build in parallel, the lead reviews, QA tests, you approve.
    trigger:
      sources: [chat, github]
      labels: [feature]
    budget: 20
    steps:
      - id: plan
        type: agent
        title: Plan & split the task
        role: tech-lead
        instructions: Break the request into independent tasks, assign a role to each, and submit the plan.
        budget: 2
        next: build
      - id: build
        type: spawn
        title: Build in parallel
        role: claude-code
        instructions: Build your task from the plan in your own worktree, run the tests, and commit.
        max_agents: 4
        next: review
      - id: review
        type: agent
        title: Review the code
        role: tech-lead
        instructions: Read every branch against the plan. Approve, or request changes naming the agent and file.
        routes:
          approved: qa
          changes_requested:
            to: build
            max_loops: 3
      - id: qa
        type: agent
        title: Test end to end
        role: qa-engineer
        instructions: Run the unit and end-to-end suites on the merged work and report passed or failed.
        routes:
          passed: approve
          failed:
            to: build
            max_loops: 2
      - id: approve
        type: approval
        title: You approve the pins
        routes:
          approved: end
          changes_requested:
            to: build
            max_loops: 3
    end:
      action: pull_request
      clean_up_worktrees: true
    """

    static let smallTask = """
    name: Small task
    version: 1
    description: One agent builds, a reviewer checks, you approve. No lead.
    trigger:
      sources: [chat, github]
      labels: [small]
    budget: 5
    steps:
      - id: build
        type: agent
        title: Build
        role: claude-code
        instructions: Build the task, run the tests, and commit.
        next: review
      - id: review
        type: agent
        title: Review
        role: pr-reviewer
        instructions: Review the branch against the task.
        routes:
          approved: approve
          changes_requested:
            to: build
            max_loops: 2
      - id: approve
        type: approval
        title: You approve
        routes:
          approved: end
          changes_requested: build
    end:
      action: pull_request
    """

    static func install(repository: URL) throws {
        let directory = ProjectConfig.directory(in: repository).appending(path: "workflows")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (featureDelivery + "\n").write(to: directory.appending(path: "feature-delivery.yaml"), atomically: true, encoding: .utf8)
        try (smallTask + "\n").write(to: directory.appending(path: "small-task.yaml"), atomically: true, encoding: .utf8)
    }
}
