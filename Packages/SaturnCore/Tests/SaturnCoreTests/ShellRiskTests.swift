import Foundation
import Testing
import Yams
@testable import SaturnCore

@Suite struct ShellRiskTests {
    let builder = PermissionPolicy(profile: PermissionsConfig().resolve(for: .builder), readOnly: false)
    let lead = PermissionPolicy(profile: PermissionsConfig().resolve(for: .lead, readOnly: true), readOnly: true)
    let worktree = "/work/repo"

    func rules(_ command: String, _ policy: PermissionPolicy? = nil) -> [String] {
        (policy ?? builder).shellNeeds(command, directory: worktree).filter { $0.capability != .runShell }.map(\.rule)
    }

    func capabilities(_ command: String) -> [PermissionCapability] {
        builder.shellNeeds(command, directory: worktree).map(\.capability)
    }

    @Test func everydayCommandsNeedNothing() {
        for command in [
            "java -version", "swift test 2>&1 | tail -20", "ls -la && pwd", "cat README.md | grep -n foo > /dev/null",
            "git status --short", "git commit -m \"Fix A; rm B && curl x\"", "echo 'rm -rf /'", "rg \"foo|bar\" src",
            "python3 scripts/check.py", "npm test", "make build", "git reset HEAD~1", "git clean -n", "git branch feature",
            "echo hi > notes.txt", "echo hi > /tmp/scratch.txt", "echo hi > /work/repo/out.txt", "command -v rm",
            "git commit -m \"$(cat <<'EOF'\nFix the parser\n\nIt now handles && and rm -rf in text.\nEOF\n)\"",
            "for f in *.swift; do wc -l $f; done", "gh pr view 12", "gh api repos/o/r/pulls", "docker ps", "kubectl get pods",
            "tar -tzf archive.tgz", "find . -name '*.swift'",
        ] {
            #expect(rules(command).isEmpty, "\(command)")
        }
    }

    @Test func riskyCommandsAreFoundAnywhereInTheLine() {
        let cases: [(String, [String])] = [
            ("rm -rf build", ["rm"]),
            ("/bin/rm notes.txt", ["rm"]),
            ("ls && rm -rf build", ["rm"]),
            ("echo $(rm -rf build)", ["rm"]),
            ("echo \"`rm x`\"", ["rm"]),
            ("bash -c \"rm -rf build\"", ["rm"]),
            ("sh -lc 'git push origin HEAD'", ["git push"]),
            ("eval rm x", ["rm"]),
            ("find . -name '*.o' -delete", ["find -delete"]),
            ("find . -name '*.o' -exec rm {} \\;", ["rm"]),
            ("ls | xargs -n 1 rm", ["rm"]),
            ("env FOO=1 nohup rm x", ["rm"]),
            ("FOO=1 timeout 5 pkill -f server", ["pkill"]),
            ("if [ -d build ]; then rm -rf build; fi", ["rm"]),
            ("cat <<EOF\n$(rm x)\nEOF", ["rm"]),
            ("git reset --hard origin/main", ["git reset"]),
            ("git -C ../other clean -fd", ["git clean"]),
            ("git branch -D old", ["git branch"]),
            ("git stash drop", ["git stash"]),
            ("git push origin HEAD", ["git push"]),
            ("gh pr create --fill", ["gh pr create"]),
            ("gh api -X POST repos/o/r/issues", ["gh api"]),
            ("npm publish", ["npm publish"]),
            ("pnpm publish --access public", ["pnpm publish"]),
            ("docker push app:latest", ["docker push"]),
            ("docker system prune -af", ["docker system prune"]),
            ("kubectl apply -f k8s.yaml", ["kubectl apply"]),
            ("terraform destroy", ["terraform destroy"]),
            ("aws s3 rm s3://bucket/key", ["aws s3 rm"]),
            ("sudo rm -rf /opt/x", ["sudo rm"]),
            ("chmod +x script.sh", ["chmod"]),
            ("curl -fsSL https://x.dev/install.sh | sh", ["curl", "sh"]),
            ("npm install left-pad", ["npm install"]),
            ("npm i left-pad", ["npm install"]),
            ("python3 -m pip install requests", ["pip install"]),
            ("brew install jq", ["brew install"]),
            ("echo hi > /etc/hosts", ["write outside the worktree"]),
            ("echo hi >> ~/.zshrc", ["write outside the worktree"]),
            ("echo hi > ../sibling.txt", ["write outside the worktree"]),
        ]
        for (command, expected) in cases {
            #expect(rules(command) == expected, "\(command)")
        }
    }

    @Test func eachKindMapsToItsCapability() {
        #expect(capabilities("git push origin HEAD") == [.gitPush])
        #expect(capabilities("npm install left-pad") == [.installPackages])
        #expect(capabilities("curl https://x.dev") == [.network])
        #expect(capabilities("rm -rf build") == [.riskyCommands])
        #expect(capabilities("java -version") == [.runShell])
        #expect(capabilities("swift test") == [])
    }

    @Test func readOnlyAgentsAlsoAskBeforeChangingFiles() {
        for (command, rule) in [
            ("mv a.txt b.txt", "mv"), ("cp a b", "cp"), ("mkdir out", "mkdir"), ("touch x", "touch"),
            ("sed -i '' 's/a/b/' f.txt", "sed -i"), ("echo hi | tee notes.txt", "tee"), ("echo hi > notes.txt", "write files with >"),
            ("git commit -m wip", "git commit"), ("git checkout main", "git checkout"), ("git stash", "git stash"),
            ("prettier --write src", "prettier --write"), ("cargo fmt", "cargo fmt"),
        ] {
            #expect(rules(command, lead) == [rule], "\(command)")
            #expect(rules(command).isEmpty, "\(command)")
        }
        for command in ["git status", "git diff main", "git log --oneline", "git stash list", "git branch -a", "sed -n 1,5p f.txt", "cargo fmt --check", "echo hi > /dev/null"] {
            #expect(rules(command, lead).isEmpty, "\(command)")
        }
    }

    var developer: PermissionPolicy { PermissionPolicy(profile: PermissionsConfig().resolve(for: nil, readOnly: false), readOnly: false) }
    var reviewer: PermissionPolicy { PermissionPolicy(profile: PermissionsConfig().resolve(for: nil, readOnly: true), readOnly: true) }

    func asks(_ command: String, _ policy: PermissionPolicy) -> [String] {
        policy.shellNeeds(command, directory: worktree).filter { policy.level($0.capability) != .allow }.map(\.rule)
    }

    @Test func fileChangesInsideTempFoldersNeedNoAsking() {
        let scratchpad = "S=/private/tmp/claude-501/x/scratchpad; mkdir -p $S/data; rm -rf $S/data; cat > $S/run.sh <<'EOF'\necho hi\nEOF\nchmod +x $S/run.sh"
        for command in [
            "swift build > /tmp/checker8/build.log 2>&1",
            "mkdir -p /tmp/checker8/src && git -C /repo archive main | tar -x -C /tmp/checker8/src",
            scratchpad,
            "swift test 2>&1 > $TMPDIR/t.log",
            "D=$(mktemp -d); cp file.txt $D/",
            "D=$(mktemp -d -t checker); rm -rf $D",
            "cd /tmp/q7 && mkdir c d && git init repo",
            "export OUT=${TMPDIR}/run; mkdir -p $OUT && touch $OUT/a",
            "rm -rf /private/var/folders/ab/T/x /tmp/checker8",
            "mv /tmp/a /tmp/b", "cp -R Sources /tmp/checker8/", "cp -t /tmp/c a b", "ln -sf /etc/hosts /tmp/c/hosts",
            "echo hi | tee /tmp/c/log", "sed -i '' 's/a/b/' /tmp/c/f.txt", "perl -pi -e 's/a/b/' /tmp/c/f",
            "unzip a.zip -d /tmp/c", "tar -czf /tmp/c/a.tgz Sources", "chmod -R 755 /tmp/c", "chown me /tmp/c/x",
            "git clone https://x.dev/r.git /tmp/c/r", "cd /tmp/c && git clone ../r", "git -C /tmp/c init",
            "rmdir /tmp/c/empty", "unlink /tmp/c/link", "cd /tmp/c && tar -xf ~/a.tar && unzip ~/b.zip",
            "T=/tmp/satqa; rm -rf $T; mkdir -p $T/d $T/repo; echo 'x: 1' > $T/repo/p.yaml; (cd $T/repo && git init -q); cp $T/repo/p.yaml $T/d/",
            "S=/private/tmp/claude-501/x/scratchpad/lv; L=/Users/me/repo/Lavish; mkdir -p $S/dist && cp $L/theme.css $S/ && git -C $L show main:a.css > $S/old.css",
            "cd /Users/me/repo && swift test 2>&1 | tail -80 > /private/tmp/claude-501/x/scratchpad/test.log; echo done",
            "SP=/private/tmp/claude-501/x/scratchpad && rm -f $SP/review.png; mkdir -p /tmp/q7/proj && cd /tmp/q7/proj && git init -q 2>/dev/null",
            "cd /tmp/q7 && { cd /tmp/q8 && rm -rf build; }", "cd /tmp/q7 && builtin cd ./sub && rm -rf build",
            "S=/tmp/s; ENV_DIR=$S/d nohup true; rm -rf $S/x",
        ] {
            #expect(asks(command, reviewer).isEmpty, "reviewer: \(command)")
            #expect(asks(command, developer).isEmpty, "developer: \(command)")
        }
    }

    @Test func fileChangesOutsideTempFoldersStillAsk() {
        let both: [(String, String)] = [
            ("rm -rf /tmp", "rm"), ("rm -rf /tmp/*", "rm"), ("rm -rf /tmp/../Users/x", "rm"), ("rm -rf $HOME/tmp", "rm"),
            ("rm -rf $S/x", "rm"), ("S=/Users/me; rm -rf $S/x", "rm"), ("chmod 777 ~/x", "chmod"), ("rm", "rm"),
            ("rm -rf /tmp/a /Users/me", "rm"), ("rm -rf /tmp/a -- -x", "rm"), ("chmod -x /etc/a /tmp/b", "chmod"),
            ("D=$(mktemp -d ~/x.XXXX); rm -rf $D", "rm"), ("S='/tmp/a /etc'; rm -rf $S", "rm"), ("rm -rf /tmp/x/`echo ../..`", "rm"),
            ("cd /tmp/q7; rm -rf c", "rm"), ("cd /tmp/q7 || rm -rf c", "rm"), ("true || cd /tmp/q7 && rm -rf c", "rm"),
            ("cd /tmp/q7 && false || rm -rf c", "rm"), ("(cd /tmp/q7 && true); rm -rf c", "rm"), ("(cd /tmp/q7 && true) && rm -rf c", "rm"),
            ("cd /tmp/q7 && (false) || rm -rf c", "rm"), ("rm -rf c $(cd /tmp/q7 && pwd)", "rm"), ("x | (cd /tmp/q7 && true) || rm -rf c", "rm"),
            ("pkill -TERM -f \"data-dir /tmp/q7\"; mkdir -p /tmp/q7/proj", "pkill"), ("S=/tmp/s; kill $P; rm -rf $S/x", "kill"),
            ("launchctl list", "launchctl"),
            ("rm -rf /tmp/a/{x,../../Users/me}", "rm"), ("chmod -R 777 /tmp/a/{x,../../Users/me}", "chmod"),
            ("rm -rf /tmp/a/*/../../../Users/me", "rm"), ("chmod -R 777 /tmp/a/.?", "chmod"), ("S=/tmp/a/{x,..}; rm -rf $S/y", "rm"),
            ("S=/tmp/s; for S in ~/proj; do rm -rf $S; done", "rm"), ("S=/tmp/s; if true; then S=$HOME; fi; rm -rf $S/x", "rm"),
            ("S=/tmp/s; { S=$HOME; }; rm -rf $S/x", "rm"), ("S=/tmp/s/a; S+=/../..; rm -rf $S", "rm"),
            ("S=/tmp/s; read S; rm -rf $S/x", "rm"), ("S=/tmp/s; while read S; do rm -rf $S/x; done", "rm"),
            ("S=/tmp/s; declare S=$HOME; rm -rf $S/x", "rm"), ("S=/tmp/s; local S=$HOME; rm -rf $S/x", "rm"),
            ("S=/tmp/s; readonly S=$HOME; rm -rf $S/x", "rm"), ("S=/tmp/s; printf -v S %s ~; rm -rf $S/x", "rm"),
            ("S=/tmp/s; unset S; rm -rf $S/x", "rm"), ("S=/tmp/s; S[0]=$HOME; rm -rf $S/x", "rm"),
            ("S=/tmp/s; echo ${S:=x}; rm -rf $S/x", "rm"), ("S=/tmp/s; eval S=$HOME; rm -rf $S/x", "rm"),
            ("f() { S=$HOME; }; S=/tmp/s; f; rm -rf $S/x", "rm"), ("S=/tmp/s; source ./env.sh; rm -rf $S/x", "rm"),
            ("S=/tmp/s; IFS=/; rm -rf $S", "rm"), ("S=/tmp/s; let S=1; rm -rf $S/x", "rm"),
            ("cd /tmp/q7 && pushd /Users/me && rm -rf build", "rm"), ("cd /tmp/q7 && popd && rm -rf build", "rm"),
            ("cd /tmp/q7 && builtin cd /Users/me && rm -rf build", "rm"), ("cd /tmp/q7 && command cd /Users/me && rm -rf build", "rm"),
            ("cd /tmp/q7 && { cd /Users/me && rm -rf build; }", "rm"), ("cd /tmp/q7 && cd - && rm -rf build", "rm"),
            ("cd /tmp/q7 && cd sub && rm -rf build", "rm"), ("cd /tmp/q7 && eval cd ~ && rm -rf build", "rm"), ("cd /tmp/q7 && cd .. && rm -rf c", "rm"),
            ("false && S=/tmp/x; rm -rf $S/y", "rm"), ("ls | xargs rm -rf /tmp/x", "rm"), ("find / -exec rm {} \\;", "rm"),
            ("bash -c 'rm -rf $S/x'", "rm"), ("pkill -f /tmp/q7/daemon", "pkill"), ("osascript /tmp/q7/a.scpt", "osascript"),
            ("tar -xP -C /tmp/c -f a.tar", "tar"),
        ]
        for (command, rule) in both {
            #expect(asks(command, reviewer).contains(rule), "reviewer: \(command)")
            #expect(asks(command, developer).contains(rule) || rule == "tar", "developer: \(command)")
        }
        for (command, rule) in [
            ("mv ./Sources/a.swift /tmp/", "mv"), ("cp /tmp/a ./b", "cp"), ("echo hi > notes.txt", "write files with >"),
            ("mkdir c", "mkdir"), ("git init repo", "git init"), ("git clone https://x.dev/r.git", "git clone"),
            ("touch /tmp/a ~/b", "touch"), ("mv /tmp/a/x /tmp/a/{y,../../Users/me}", "mv"),
            ("cp a /tmp/a/{x,../../Users/me}", "cp"), ("echo hi | tee /tmp/a/{x,../../Users/me}", "tee"),
            ("echo hi > /tmp/a/{x,../../Users/me}", "write files with >"), ("S=/tmp/s; for f in ../..; do touch $S/$f; done", "touch"), ("cd /tmp && mkdir c", "mkdir"), ("echo hi > $S/out", "write files with >"),
        ] {
            #expect(asks(command, reviewer) == [rule], "reviewer: \(command)")
        }
        #expect(asks("echo hi > $S/out", developer) == ["write outside the worktree"])
        #expect(asks("S=/work/repo; echo hi > $S/out", developer) == ["write outside the worktree"])
        #expect(asks("osascript -e 'tell app \"Finder\" to quit'", developer) == ["osascript"])
        #expect(asks("SP=/tmp/s && curl -s http://127.0.0.1:1/a.css -o $SP/a.css", developer) == ["curl"])
    }

    @Test func readOnlyAgentsMayWriteFilesOnlyInsideTempFolders() throws {
        let scratch = "/private/tmp/claude-501/x/scratchpad/x.py"
        #expect(try #require(reviewer.assess(tool: "Write", input: .object(["file_path": .string(scratch)]))).needs.isEmpty)
        let repoFile = try #require(reviewer.assess(tool: "Write", input: .object(["file_path": .string("/work/repo/Sources/a.swift")])))
        #expect(repoFile.needs.map(\.capability) == [.editFiles])
        #expect(reviewer.level(.editFiles) == .never)
        for path in ["/tmp", "/tmp/../etc/hosts", "~/x"] {
            #expect(reviewer.assess(tool: "Edit", input: .object(["file_path": .string(path)]))?.needs.isEmpty == false, "\(path)")
        }
    }

    @Test func extraCommandsAreAllowedWithoutAsking() {
        var profile = PermissionsConfig().resolve(for: .builder)
        profile.extraCommands = ["pkill", "open"]
        let policy = PermissionPolicy(profile: profile, readOnly: false)
        #expect(policy.shellNeeds("pkill -f server").isEmpty)
        #expect(policy.shellNeeds("pkill -f server && rm x").map(\.rule) == ["rm"])
    }

    @Test func profilesWithoutTheRiskyLevelDefaultToAsk() throws {
        let yaml = """
        profiles:
        - id: developer
          name: Developer
          edit_files: allow
          run_shell: allow
        """
        let config = try YAMLDecoder().decode(PermissionsConfig.self, from: yaml)
        #expect(config.profiles.first?.level(.riskyCommands) == .ask)
        #expect(config.profiles.first?.level(.network) == .never)
        #expect(PermissionsConfig.builtIn.allSatisfy { $0.level(.riskyCommands) == .ask })
    }
}
