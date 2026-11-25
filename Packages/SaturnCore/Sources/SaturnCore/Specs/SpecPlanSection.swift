import Foundation

struct SpecPlanSection {
    var document: SpecDocument
    var workflow: WorkflowDefinition?

    static let permissionLine = "Permission prompts for risky commands, such as deleting files, installing packages or using the network"

    var agentCount: Int { document.workers.count + 1 }

    var html: String {
        [workflowBlock, workersBlock, totalBlock, remainingBlock, approveBlock].compactMap(\.self).joined(separator: "\n")
    }

    var remainingApprovals: [String] {
        let steps = workflow?.steps ?? []
        let fromSteps = steps.compactMap { step -> String? in
            let title = step.displayTitle
            switch step.type {
            case .approval: return "\(title): you approve the finished work"
            case .gates: return "\(title): you decide on blocking findings"
            default:
                guard step.routes.keys.contains(where: ["changes_requested", "failed"].contains) else { return nil }
                return "\(title): may send the work back for changes"
            }
        }
        var lines = fromSteps
        if workflow?.steps.contains(where: { $0.type == .spawn }) == true {
            lines.insert("The plan: goes straight to build when it fits the approved workers; a plan with more builders or a new role waits for you", at: 0)
        }
        return lines + [Self.permissionLine]
    }

    private var workflowBlock: String {
        guard let workflow else {
            let named = document.workflow.map { " <code>\(SpecPageRenderer.escape($0))</code> isn’t in this project, so its steps aren’t shown." }
            return "<p class=\"workflow\">Workflow:\(named ?? " not resolved yet.")</p>"
        }
        let description = workflow.description.isEmpty ? "" : " · <span class=\"reason\">\(SpecPageRenderer.inline(workflow.description))</span>"
        let steps = workflow.steps.map { step in
            "<li>\(SpecPageRenderer.escape(step.displayTitle)) <span class=\"role\">\(step.type.rawValue)</span></li>"
        }
        return """
            <p class="workflow">Workflow: <strong>\(SpecPageRenderer.escape(workflow.displayName))</strong> <code>\(SpecPageRenderer.escape(workflow.id))</code>\(description)</p>
            <ol class="steps">
            \(steps.joined(separator: "\n"))
            </ol>
            """
    }

    private var workersBlock: String {
        guard !document.workers.isEmpty else { return "<p>No workers listed yet.</p>" }
        let rows = document.workers.map { worker in
            let cells = [
                SpecPageRenderer.escape(worker.role),
                "<strong>\(SpecPageRenderer.escape(worker.name))</strong>",
                worker.reason.map(SpecPageRenderer.inline) ?? "",
                worker.skills.map { "<code>\(SpecPageRenderer.escape($0))</code>" }.joined(separator: " "),
                worker.model.map(SpecPageRenderer.escape) ?? "",
            ]
            return "<tr>" + cells.map { "<td>\($0)</td>" }.joined() + "</tr>"
        }
        return """
            <div class="table"><table class="workers">
            <thead><tr><th>Role</th><th>Name</th><th>Reason</th><th>Skills</th><th>Model</th></tr></thead>
            <tbody>
            \(rows.joined(separator: "\n"))
            </tbody>
            </table></div>
            """
    }

    private var totalBlock: String {
        let workers = document.workers.count
        return "<p class=\"total\"><strong>\(agentCount) agent\(agentCount == 1 ? "" : "s") total</strong> (the lead and \(workers) worker\(workers == 1 ? "" : "s"))</p>"
    }

    private var remainingBlock: String {
        "<h3>Approvals after you start</h3>\n" + SpecPageRenderer.list(remainingApprovals)
    }

    private var approveBlock: String? {
        guard document.status == .draft || document.status == .rejected else { return nil }
        let id = SpecFeedback.approveID
        let action = "if(window.lavish){window.lavish.queuePrompt('approve',{element:this,selector:'#\(id)',tag:'button',text:'Approve &amp; start'});window.lavish.sendQueuedPrompts();this.disabled=true;this.textContent='Starting…'}"
        return """
            <div class="approve"><button id="\(id)" type="button" onclick="\(action)">Approve &amp; start</button><span class="hint">Approves this spec, its workflow and \(agentCount) agents, and starts the run.</span></div>
            """
    }
}
