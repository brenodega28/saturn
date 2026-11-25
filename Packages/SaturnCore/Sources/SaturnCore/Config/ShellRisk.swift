import Foundation

public struct PermissionNeed: Sendable, Hashable {
    public var capability: PermissionCapability
    public var rule: String
    public var command: String

    public init(capability: PermissionCapability, rule: String, command: String) {
        self.capability = capability
        self.rule = rule
        self.command = command
    }
}

enum ShellRisk {
    static let networkTools: Set<String> = ["curl", "wget", "ssh", "scp", "sftp", "rsync", "nc", "ncat", "netcat", "telnet", "ftp", "http", "https", "xh"]

    static let riskyTools: Set<String> = [
        "rm", "rmdir", "unlink", "shred", "srm", "dd", "truncate", "diskutil", "fdisk", "mkfs",
        "kill", "pkill", "killall", "shutdown", "reboot", "halt", "launchctl",
        "chmod", "chown", "chgrp", "chflags", "crontab", "osascript", "security", "csrutil", "spctl",
    ]

    static let elevators: Set<String> = ["sudo", "doas", "su"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
    static let packageManagers: Set<String> = ["npm", "pnpm", "yarn", "bun"]

    static let cloudTools: [String: Int] = [
        "aws": 2, "gcloud": 2, "az": 2,
        "heroku": 1, "fly": 1, "flyctl": 1, "vercel": 1, "netlify": 1, "firebase": 1, "wrangler": 1, "railway": 1,
    ]

    static let subcommandTools: Set<String> = [
        "git", "npm", "pnpm", "yarn", "bun", "npx", "bunx", "docker", "podman", "kubectl", "oc", "helm", "brew",
        "cargo", "go", "pip", "pip3", "pipx", "uv", "poetry", "gem", "bundle", "swift", "xcrun", "terraform", "tofu",
        "pulumi", "systemctl", "defaults", "apt", "apt-get", "yum", "dnf", "zypper", "conda", "mamba", "mas", "port",
        "dotnet", "mix", "composer", "make", "rails", "rake", "twine", "pod", "flit",
    ]

    static let installSubcommands: [String: Set<String>] = {
        let javascript: Set<String> = ["install", "i", "add", "ci", "uninstall", "un", "remove", "rm", "r", "update", "upgrade", "up", "link"]
        let system: Set<String> = ["install", "remove", "purge", "upgrade", "update", "autoremove", "reinstall"]
        return [
            "npm": javascript, "pnpm": javascript, "yarn": javascript, "bun": javascript,
            "pip": ["install", "uninstall", "download"], "pip3": ["install", "uninstall", "download"],
            "uv": ["add", "remove", "sync", "pip", "tool"], "poetry": ["add", "remove", "install", "update"],
            "gem": ["install", "uninstall", "update"], "bundle": ["install", "update", "add", "remove"],
            "cargo": ["add", "remove", "install", "uninstall", "update"], "go": ["get", "install"],
            "brew": ["install", "uninstall", "reinstall", "upgrade", "remove", "rm", "tap", "untap", "update"],
            "apt": system, "apt-get": system, "yum": system, "dnf": system, "zypper": system,
            "conda": ["install", "remove", "update", "create"], "mamba": ["install", "remove", "update", "create"],
            "mas": ["install", "uninstall", "upgrade"], "port": ["install", "uninstall", "upgrade"],
            "pipx": ["install", "uninstall", "upgrade", "reinstall"], "composer": ["install", "require", "remove", "update"],
        ]
    }()

    static let riskySubcommands: [String: Set<String>] = {
        let publishing: Set<String> = ["publish", "unpublish", "deprecate", "dist-tag", "owner", "access", "token", "adduser", "login", "logout"]
        let containers: Set<String> = ["push", "rm", "rmi", "kill", "stop", "login", "logout"]
        let kubernetes: Set<String> = [
            "apply", "delete", "create", "replace", "patch", "scale", "rollout", "drain", "cordon", "uncordon", "edit",
            "label", "annotate", "set", "taint", "exec", "cp", "run", "expose", "autoscale",
        ]
        let terraform: Set<String> = ["apply", "destroy", "import", "state", "taint", "untaint", "force-unlock"]
        return [
            "npm": publishing, "pnpm": publishing, "yarn": publishing, "bun": publishing,
            "cargo": ["publish", "yank", "owner", "login"], "poetry": ["publish"], "uv": ["publish"],
            "gem": ["push", "yank", "owner", "signin"], "twine": ["upload"], "pod": ["trunk"], "flit": ["publish"], "dotnet": ["nuget"],
            "docker": containers, "podman": containers, "kubectl": kubernetes, "oc": kubernetes,
            "helm": ["install", "upgrade", "uninstall", "delete", "rollback", "push"],
            "terraform": terraform, "tofu": terraform,
            "pulumi": ["up", "destroy", "import", "state", "cancel", "refresh"],
            "systemctl": ["start", "stop", "restart", "reload", "enable", "disable", "kill", "mask", "unmask", "daemon-reload", "isolate"],
            "defaults": ["write", "delete", "import", "rename"],
        ]
    }()

    static let containerNamespaces: Set<String> = ["system", "container", "image", "volume", "network", "builder", "buildx", "compose"]
    static let containerNamespaceActions: Set<String> = ["prune", "rm", "remove", "down", "kill", "stop", "push"]

    static let githubWrites: [String: Set<String>] = [
        "pr": ["create", "merge", "close", "edit", "comment", "review", "reopen", "ready", "lock", "unlock"],
        "issue": ["create", "close", "edit", "comment", "delete", "reopen", "transfer", "lock", "unlock", "pin", "unpin", "develop"],
        "release": ["create", "delete", "edit", "upload", "delete-asset"],
        "repo": ["create", "delete", "fork", "rename", "edit", "archive", "unarchive", "sync", "deploy-key"],
        "gist": ["create", "delete", "edit", "rename"],
        "secret": ["set", "delete", "remove"],
        "variable": ["set", "delete"],
        "workflow": ["run", "enable", "disable"],
        "run": ["rerun", "cancel", "delete"],
        "label": ["create", "edit", "delete", "clone"],
        "cache": ["delete"],
        "codespace": ["create", "delete", "stop"],
    ]

    static let gitWrites: Set<String> = [
        "add", "commit", "restore", "mv", "rm", "merge", "rebase", "reset", "checkout", "switch", "cherry-pick", "revert",
        "apply", "am", "pull", "clean", "init", "clone", "notes", "gc", "prune", "submodule", "sparse-checkout", "update-index",
    ]

    static let aliases: [String: String] = ["i": "install", "un": "uninstall", "rm": "uninstall", "r": "uninstall", "remove": "uninstall", "up": "update", "upgrade": "update"]

    static func needs(of command: ShellCommandLine.Command, readOnly: Bool, directory: String?) -> [PermissionNeed] {
        command.redirects.compactMap { redirectNeed($0, readOnly: readOnly, directory: directory) }
            + needs(ofWords: command.words, readOnly: readOnly, directory: directory)
    }

    static func needs(ofWords original: [String], readOnly: Bool, directory: String?) -> [PermissionNeed] {
        guard let words = unwrapped(original), let first = words.first else { return [] }
        let program = basename(first)
        let arguments = Array(words.dropFirst())
        let text = words.joined(separator: " ")
        if program == "xargs" {
            return needs(ofWords: xargsCommand(arguments), readOnly: readOnly, directory: directory)
        }
        if let script = nestedScript(program, arguments) {
            return ShellCommandLine(script).commands.flatMap { needs(of: $0, readOnly: readOnly, directory: directory) }
        }
        if program == "find" {
            return findNeeds(arguments, text: text, readOnly: readOnly, directory: directory)
        }
        if program.hasPrefix("python"), arguments.first == "-m", arguments.count > 1, arguments[1] == "pip" {
            return needs(ofWords: ["pip"] + arguments.dropFirst(2), readOnly: readOnly, directory: directory)
        }
        let (capability, rule) = classify(program, arguments, readOnly: readOnly)
        return [PermissionNeed(capability: capability, rule: rule, command: text)]
    }

    static func classify(_ program: String, _ arguments: [String], readOnly: Bool) -> (PermissionCapability, String) {
        let positional = positional(arguments)
        let sub = positional.first
        if networkTools.contains(program) { return (.network, program) }
        if riskyTools.contains(program) || program.hasPrefix("mkfs.") { return (.riskyCommands, program) }
        if elevators.contains(program) {
            let target = unwrapped(Array(arguments.drop { $0.hasPrefix("-") }))?.first.map(basename)
            return (.riskyCommands, [program, target].compactMap(\.self).joined(separator: " "))
        }
        if shells.contains(program), positional.isEmpty { return (.riskyCommands, program) }
        if let depth = cloudTools[program] { return (.riskyCommands, ([program] + positional.prefix(depth)).joined(separator: " ")) }
        switch program {
        case "git":
            return git(arguments, readOnly: readOnly)
        case "gh":
            if let rule = github(arguments, positional: positional) { return (.riskyCommands, rule) }
        case "docker", "podman":
            if let sub, containerNamespaces.contains(sub), positional.count > 1, containerNamespaceActions.contains(positional[1]) {
                return (.riskyCommands, "\(program) \(sub) \(positional[1])")
            }
        default:
            break
        }
        if program == "yarn", sub == nil {
            return (.installPackages, "yarn install")
        }
        if let sub, installSubcommands[program]?.contains(sub) == true {
            return (.installPackages, "\(program) \(normalized(sub, for: program))")
        }
        if let sub, riskySubcommands[program]?.contains(sub) == true {
            return (.riskyCommands, "\(program) \(sub)")
        }
        if readOnly, let rule = fileChangingRule(program, arguments, positional: positional) {
            return (.riskyCommands, rule)
        }
        return (.runShell, key(program, positional))
    }

    static func git(_ arguments: [String], readOnly: Bool) -> (PermissionCapability, String) {
        var index = 0
        while index < arguments.count, arguments[index].hasPrefix("-") {
            index += ["-C", "-c", "--git-dir", "--work-tree", "--namespace"].contains(arguments[index]) ? 2 : 1
        }
        guard index < arguments.count else { return (.runShell, "git") }
        let sub = arguments[index]
        let rest = Array(arguments.dropFirst(index + 1))
        let positional = positional(rest)
        let rule = "git \(sub)"
        func has(_ flags: String...) -> Bool { rest.contains { flags.contains($0) } }
        let risky: Bool
        switch sub {
        case "push": return (.gitPush, rule)
        case "reset": risky = has("--hard", "--merge", "--keep")
        case "clean": risky = !has("-n", "--dry-run")
        case "branch": risky = has("-d", "-D", "--delete", "-M", "-f", "--force")
        case "stash": risky = ["drop", "clear"].contains(positional.first ?? "")
        case "worktree": risky = ["remove", "prune"].contains(positional.first ?? "")
        case "tag": risky = has("-d", "--delete")
        case "filter-branch", "filter-repo": risky = true
        case "reflog": risky = ["expire", "delete"].contains(positional.first ?? "")
        case "update-ref": risky = has("-d")
        case "config": risky = has("--global", "--system")
        default: risky = false
        }
        if risky || (readOnly && gitChangesFiles(sub, rest: rest, positional: positional)) { return (.riskyCommands, rule) }
        return (.runShell, rule)
    }

    static func gitChangesFiles(_ sub: String, rest: [String], positional: [String]) -> Bool {
        func has(_ flags: String...) -> Bool { rest.contains { flags.contains($0) } }
        switch sub {
        case _ where gitWrites.contains(sub): return true
        case "stash": return !["list", "show"].contains(positional.first ?? "push")
        case "tag": return !positional.isEmpty && !has("-l", "--list")
        case "branch":
            return has("-m", "-M", "-c", "-C", "-u", "--set-upstream-to", "--unset-upstream", "--move", "--copy")
                || (!positional.isEmpty && !has("-l", "--list", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at"))
        case "worktree": return ["add", "remove", "move", "prune", "repair", "lock", "unlock"].contains(positional.first ?? "")
        case "remote": return ["add", "remove", "rm", "rename", "set-url", "set-head", "prune"].contains(positional.first ?? "")
        case "config": return positional.count >= 2 || has("--unset", "--unset-all", "--add", "--replace-all", "--edit", "-e", "--remove-section", "--rename-section")
        default: return false
        }
    }

    static func github(_ arguments: [String], positional: [String]) -> String? {
        guard let group = positional.first else { return nil }
        if group == "api" {
            let method = arguments.firstIndex { $0 == "-X" || $0 == "--method" }.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1].uppercased() : nil }
            let sendsFields = arguments.contains { ["-f", "-F", "--field", "--raw-field", "--input"].contains($0) || $0.hasPrefix("--method=") || $0.hasPrefix("-X") && $0.count > 2 }
            return (method.map { $0 != "GET" } ?? false) || sendsFields ? "gh api" : nil
        }
        guard positional.count > 1, githubWrites[group]?.contains(positional[1]) == true else { return nil }
        return "gh \(group) \(positional[1])"
    }

    static func fileChangingRule(_ program: String, _ arguments: [String], positional: [String]) -> String? {
        func has(_ flags: String...) -> Bool { arguments.contains { flags.contains($0) } }
        func shortFlag(_ letter: Character) -> Bool { arguments.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains(letter) } }
        switch program {
        case "mv", "cp", "mkdir", "touch", "ln", "install", "patch", "unzip", "split":
            return program
        case "tee":
            return positional.isEmpty ? nil : program
        case "sed", "gsed":
            return shortFlag("i") || arguments.contains { $0.hasPrefix("--in-place") } ? "\(program) -i" : nil
        case "perl":
            return shortFlag("i") ? "perl -i" : nil
        case "tar":
            let mode = arguments.first ?? ""
            let bundled = !mode.hasPrefix("--") && (mode.contains("x") || mode.contains("c"))
            return bundled || has("--extract", "--create", "--get") ? "tar" : nil
        case "prettier":
            return has("--write", "-w") ? "prettier --write" : nil
        case "eslint":
            return has("--fix") ? "eslint --fix" : nil
        case "gofmt", "goimports":
            return has("-w") ? program : nil
        case "black", "rustfmt":
            return has("--check", "--diff") ? nil : program
        case "ruff":
            return (positional.first == "format" && !has("--check", "--diff")) || has("--fix") ? "ruff" : nil
        case "swiftformat":
            return has("--lint", "--dryrun") ? nil : program
        case "swift-format", "clang-format":
            return has("-i", "--in-place") ? program : nil
        case "cargo":
            if positional.first == "fmt" { return has("--check") ? nil : "cargo fmt" }
            return positional.first == "fix" ? "cargo fix" : nil
        case "go":
            return ["fmt", "generate"].contains(positional.first ?? "") ? "go \(positional[0])" : nil
        case "npm", "pnpm", "yarn", "bun":
            return positional.first == "version" ? "\(program) version" : nil
        default:
            return nil
        }
    }

    static func redirectNeed(_ target: String, readOnly: Bool, directory: String?) -> PermissionNeed? {
        guard !target.hasPrefix("/dev/") else { return nil }
        let command = "> \(target)"
        if readOnly { return PermissionNeed(capability: .riskyCommands, rule: "write files with >", command: command) }
        guard writesOutside(target, directory: directory) else { return nil }
        return PermissionNeed(capability: .riskyCommands, rule: "write outside the worktree", command: command)
    }

    static func writesOutside(_ target: String, directory: String?) -> Bool {
        if target.hasPrefix("~") || target.hasPrefix("$") { return true }
        guard target.hasPrefix("/") else {
            var depth = 0
            for component in target.split(separator: "/") {
                if component == ".." { depth -= 1 } else if component != "." { depth += 1 }
                if depth < 0 { return true }
            }
            return false
        }
        let path = URL(filePath: target).standardized.path
        var roots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        if let directory {
            roots.append(directory)
            if directory.hasPrefix("/private/") { roots.append(String(directory.dropFirst("/private".count))) } else { roots.append("/private" + directory) }
        }
        return !roots.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    static func findNeeds(_ arguments: [String], text: String, readOnly: Bool, directory: String?) -> [PermissionNeed] {
        var found: [PermissionNeed] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "-delete" {
                found.append(PermissionNeed(capability: .riskyCommands, rule: "find -delete", command: text))
            } else if ["-exec", "-execdir", "-ok", "-okdir"].contains(argument) {
                var inner: [String] = []
                while index < arguments.count, arguments[index] != ";", arguments[index] != "+" {
                    inner.append(arguments[index])
                    index += 1
                }
                index += 1
                found += needs(ofWords: inner, readOnly: readOnly, directory: directory)
            }
        }
        return found.isEmpty ? [PermissionNeed(capability: .runShell, rule: "find", command: text)] : found
    }

    static func nestedScript(_ program: String, _ arguments: [String]) -> String? {
        if program == "eval" { return arguments.joined(separator: " ") }
        guard shells.contains(program),
              let flag = arguments.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }),
              arguments.indices.contains(flag + 1) else { return nil }
        return arguments[flag + 1]
    }

    static func xargsCommand(_ arguments: [String]) -> [String] {
        let takesValue: Set<String> = ["-n", "-I", "-L", "-P", "-s", "-d", "-E", "-a", "-J", "-R", "-S"]
        var index = 0
        while index < arguments.count, arguments[index].hasPrefix("-") {
            index += takesValue.contains(arguments[index]) ? 2 : 1
        }
        return Array(arguments.dropFirst(index))
    }

    static func unwrapped(_ original: [String]) -> [String]? {
        var words = original
        while let first = words.first {
            if first.contains("="), first.first.map({ $0.isLetter || $0 == "_" }) == true,
               first.prefix { $0 != "=" }.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                words.removeFirst()
                continue
            }
            switch basename(first) {
            case "{", "}", "!", "if", "elif", "while", "until", "then", "do", "else", "nohup", "stdbuf":
                words.removeFirst()
                if basename(first) == "stdbuf" { words = Array(words.drop { $0.hasPrefix("-") }) }
            case "env":
                words.removeFirst()
                while let flag = words.first, flag.hasPrefix("-") {
                    words.removeFirst()
                    if ["-u", "-C", "-S"].contains(flag), !words.isEmpty { words.removeFirst() }
                }
            case "time":
                words = Array(words.dropFirst().drop { $0.hasPrefix("-") })
            case "command", "builtin", "exec":
                if words.count > 1, ["-v", "-V"].contains(words[1]) { return nil }
                words = Array(words.dropFirst().drop { $0.hasPrefix("-") })
            case "nice":
                words.removeFirst()
                if words.first == "-n" { words.removeFirst(min(2, words.count)) } else if words.first?.hasPrefix("-") == true { words.removeFirst() }
            case "timeout", "gtimeout":
                words.removeFirst()
                while let flag = words.first, flag.hasPrefix("-") {
                    words.removeFirst()
                    if ["-s", "-k", "--signal", "--kill-after"].contains(flag), !words.isEmpty { words.removeFirst() }
                }
                if !words.isEmpty { words.removeFirst() }
            default:
                if words.last == "}" { words.removeLast() }
                return words
            }
        }
        return words
    }

    static func positional(_ arguments: [String]) -> [String] {
        arguments.filter { !$0.hasPrefix("-") }
    }

    static func key(_ program: String, _ positional: [String]) -> String {
        guard subcommandTools.contains(program), let sub = positional.first else { return program }
        return "\(program) \(sub)"
    }

    static func normalized(_ sub: String, for program: String) -> String {
        packageManagers.contains(program) || program == "brew" ? aliases[sub] ?? sub : sub
    }

    static func basename(_ word: String) -> String {
        word.split(separator: "/").last.map(String.init) ?? word
    }
}
