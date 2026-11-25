import Foundation

extension SaturnHost {
    func wireSpecReviews() {
        driver.specReviews = specReviews
        specReviews.makeRuntime = { [weak self] in
            guard let self else { throw LavishError.packageMissing }
            return try await self.lavishRuntime()
        }
        specReviews.deliver = { [weak self] taskId, message in
            try? await self?.leadChat.deliverSpecFeedback(message, taskId: taskId)
        }
        specReviews.approve = { [weak self] taskId in
            guard let self else { throw SpecReviewError.approvalUnavailable }
            guard let chat = try database.task(id: taskId), let project = try database.project(id: chat.projectId) else { throw SpecReviewError.noDraft }
            if chat.isClosed { throw SpecReviewError.closed }
            _ = try await leadChat.approveSpec(taskId: taskId, in: project)
        }
        specReviews.drafted = { [weak self] projectId, taskId, path in
            self?.server?.broadcast(.event(.specDrafted(projectId: projectId, taskId: taskId, path: path)))
        }
        specReviews.ended = { [weak self] taskId in
            self?.server?.broadcast(.event(.specReviewEnded(taskId: taskId)))
        }
    }

    func wireChatRelay() {
        driver.daemonID = identity.id
        driver.chatRouting = chatRelay
    }

    func lavishRuntime() async throws -> LavishRuntime {
        let environment = runtime.processEnvironment
        let lavish = try LavishRuntime.locate(paths: paths, environment: environment, launch: options.lavishLauncher ?? LavishRuntime.launchProcess)
        guard options.lavishLauncher == nil else { return lavish }
        let version = await LavishRuntime.nodeVersion(lavish.node, runner: CommandRunner(environment: environment))
        if let version, let major = LavishRuntime.major(of: version), major < LavishRuntime.requiredNodeMajor {
            throw LavishError.nodeTooOld(found: version, required: LavishRuntime.requiredNodeMajor)
        }
        return lavish
    }
}
