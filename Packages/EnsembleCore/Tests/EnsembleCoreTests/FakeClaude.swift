import Foundation
@testable import EnsembleCore

enum FakeClaude {
    static let script = #"""
    session=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--session-id" ] || [ "$prev" = "--resume" ]; then session="$arg"; fi
      prev="$arg"
    done
    printf '%s\n' "$(printf '%s' "$*" | tr '\n' ' ')" >> "$FAKE_DIR/args.log"
    echo "key=${ANTHROPIC_API_KEY:-} token=${ANTHROPIC_AUTH_TOKEN:-}" >> "$FAKE_DIR/env.log"
    mode="${FAKE_MODE:-normal}"
    [ -f "$FAKE_DIR/mode" ] && mode="$(cat "$FAKE_DIR/mode")"
    source="none"
    [ -n "${ANTHROPIC_API_KEY:-}" ] && source="ANTHROPIC_API_KEY"
    [ "$mode" = "wrongsource" ] && source="apiKeyHelper"
    cost=0
    mcpfile=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--mcp-config" ]; then mcpfile="$arg"; fi
      prev="$arg"
    done
    call_tool() {
      url=$(sed -E 's/.*"url":"([^"]+)".*/\1/' "$mcpfile" | sed 's#\\/#/#g')
      printf '%s' "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" > "$FAKE_DIR/request-$$.json"
      curl -s -X POST -H 'Content-Type: application/json' --data-binary @"$FAKE_DIR/request-$$.json" "$url" >> "$FAKE_DIR/mcp.log"
      echo >> "$FAKE_DIR/mcp.log"
    }
    workflow_turn() {
      if printf '%s' "$1" | grep -q 'Roles that can build'; then
        call_tool submit_plan '{"summary":"Two parallel tasks","tasks":[{"title":"Add alpha","role":"claude-code","files":["alpha.txt"]},{"title":"Add beta","role":"claude-code","files":["beta.txt"]}]}'
        return
      fi
      if printf '%s' "$1" | grep -q 'submit_verdict'; then
        if printf '%s' "$1" | grep -q '`passed` or `failed`'; then
          call_tool submit_verdict '{"outcome":"passed","summary":"All tests pass"}'
        elif [ -f "$FAKE_DIR/reject" ]; then
          rm "$FAKE_DIR/reject"
          call_tool submit_verdict '{"outcome":"changes_requested","summary":"Alpha needs a second line","issues":[{"description":"Add a second line to alpha.txt","file":"alpha.txt"}]}'
        else
          call_tool submit_verdict '{"outcome":"approved","summary":"Looks good"}'
        fi
        return
      fi
      if printf '%s' "$1" | grep -q 'Resolve a merge conflict'; then
        for conflicted in $(git diff --name-only --diff-filter=U); do
          grep -v '^<<<<<<<\|^=======\|^>>>>>>>' "$conflicted" > "$conflicted.resolved"
          mv "$conflicted.resolved" "$conflicted"
          git add "$conflicted"
        done
        git -c user.name=Fake -c user.email=fake@x commit -q --no-edit >/dev/null 2>&1
        call_tool submit_result '{"summary":"Resolved the conflict keeping both sides"}'
        return
      fi
      if printf '%s' "$1" | grep -q 'submit_result'; then
        name=$(basename "$PWD")
        file="$name.txt"
        if printf '%s' "$1" | grep -q 'Your task: Add alpha\|for “Add alpha”'; then file="alpha.txt"; fi
        if printf '%s' "$1" | grep -q 'Your task: Add beta\|for “Add beta”'; then file="beta.txt"; fi
        echo "work by $name" >> "$file"
        git add "$file" >/dev/null 2>&1
        git -c user.name=Fake -c user.email=fake@x commit -qm "Work on $file" >/dev/null 2>&1
        call_tool create_pin "{\"file\":\"$PWD/$file\",\"start_line\":1,\"end_line\":1,\"title\":\"Check $file\",\"explanation\":\"New file\"}"
        call_tool submit_result "{\"summary\":\"Wrote $file\"}"
      fi
    }
    init() {
      printf '{"type":"system","subtype":"init","session_id":"%s","model":"claude-fake-1","cwd":"%s","claude_code_version":"9.9.9","apiKeySource":"%s"}\n' "$session" "$PWD" "$source"
      if [ "$mode" = "wrongsource" ]; then sleep 5; fi
    }
    result() {
      cost=$((cost + 1))
      printf '{"type":"result","subtype":"%s","is_error":%s,"result":"ok","total_cost_usd":0.0%s,"duration_ms":5,"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20},"permission_denials":[]}\n' "$1" "$2" "$cost"
    }
    while IFS= read -r line; do
      case "$line" in
        *control_request*)
          printf '{"type":"control_response","response":{"subtype":"success"}}\n'
          printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}\n'
          result error_during_execution true
          ;;
        *'"type":"user"'*)
          init
          if [ "$mode" = "crash" ]; then echo "boom: invalid api key" >&2; exit 3; fi
          if [ "$mode" = "workflow" ]; then
            workflow_turn "$line"
            result success false
            continue
          fi
          printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Working on it"},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"%s/README.md","old_string":"hello","new_string":"hello\\nworld"}}]}}\n' "$PWD"
          printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"updated","is_error":false}]}}\n'
          if [ "$mode" = "slow" ]; then
            printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"pytest -q"}}]}}\n'
            continue
          fi
          printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}\n'
          result success false
          ;;
      esac
    done
    if [ "$mode" = "lingering" ]; then (sleep 30) & fi
    exit 0
    """#

    static func install() throws -> URL {
        try FakeTools.make(["claude": script])
    }
}

@MainActor
struct AgentHarness {
    let repo: TestRepository
    let bin: URL
    let data: URL
    let database: AppDatabase
    let runtime: AgentRuntime
    let project: Project

    static func make(mode: String = "normal", provider: ProviderMode? = .claudeSignIn, secrets: InMemorySecretStore = InMemorySecretStore()) async throws -> AgentHarness {
        let repo = try await TestRepository.make()
        let bin = try FakeClaude.install()
        let data = FileManager.default.temporaryDirectory.appending(path: "ensemble-data-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try mode.write(to: bin.appending(path: "mode"), atomically: true, encoding: .utf8)
        let database = try AppDatabase.open(at: data.appending(path: "ensemble.sqlite"))
        let project = try database.openProject(at: repo.root)
        let runtime = makeRuntime(database: database, data: data, bin: bin, provider: provider, secrets: secrets)
        return AgentHarness(repo: repo, bin: bin, data: data, database: database, runtime: runtime, project: project)
    }

    static func makeRuntime(
        database: AppDatabase,
        data: URL,
        bin: URL,
        provider: ProviderMode? = .claudeSignIn,
        secrets: InMemorySecretStore = InMemorySecretStore()
    ) -> AgentRuntime {
        var environment = ProcessInfo.processInfo.environment
        environment["FAKE_DIR"] = bin.path
        environment["ANTHROPIC_API_KEY"] = "sk-ant-from-shell"
        environment["ANTHROPIC_AUTH_TOKEN"] = "token-from-shell"
        return AgentRuntime(
            database: database,
            paths: AppPaths(root: data),
            secrets: secrets,
            providerMode: provider,
            claudeExecutable: bin.appending(path: "claude"),
            processEnvironment: environment,
            stopGracePeriod: .seconds(2)
        )
    }

    func setMode(_ mode: String) throws {
        try mode.write(to: bin.appending(path: "mode"), atomically: true, encoding: .utf8)
    }

    func launchEnvironments() -> [String] {
        ((try? String(contentsOf: bin.appending(path: "env.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func launches() -> [String] {
        ((try? String(contentsOf: bin.appending(path: "args.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func spawn(_ name: String = "Dev 1", task: String = "Add a world line to the README") async throws -> AgentSession {
        try await runtime.spawn(in: project, name: name, model: .haiku, task: task, git: repo.git)
    }

    func cleanUp() {
        repo.delete()
        try? FileManager.default.removeItem(at: bin)
        try? FileManager.default.removeItem(at: data)
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for condition"])
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}
