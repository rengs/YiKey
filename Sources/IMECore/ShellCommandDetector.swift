import Foundation

/// 终端命令 / shell 输出识别（剪贴板监测用）：评分制。
/// 命令特征加分（提示符、命令名、-x/--flag、| && || ; > >>、$VAR/$()/反引号、路径、续行、FOO=bar、git 输出、路径:行号报错…），
/// 自然语言特征减分（首字母大写、句末 . ? !、the/you/please 等常用词）。每行打分，命令行占多数才判为命令。
public enum ShellCommandDetector {
    /// 一行达到这个分数算“命令行”
    public static let lineThreshold = 3

    /// 几乎只会作为命令出现的命令名（首词命中 +3）
    static let strongCommands: Set<String> = [
        "ls", "cd", "rg", "grep", "egrep", "fgrep", "git", "gh", "brew", "npm", "npx", "pnpm", "yarn", "bun", "deno",
        "pip", "pip3", "pipx", "python", "python3", "ruby", "gem", "bundle", "swift", "swiftc", "xcodebuild", "xcrun",
        "xcode-select", "pod", "mkdir", "rmdir", "chmod", "chown", "chgrp", "sudo", "su", "ssh", "scp", "rsync", "sftp",
        "curl", "wget", "docker", "docker-compose", "podman", "kubectl", "helm", "terraform", "ansible", "cmake",
        "cargo", "rustc", "rustup", "gcc", "g++", "clang", "javac", "java", "mvn", "gradle", "node", "nvm", "tsc",
        "echo", "printf", "export", "unset", "alias", "defaults", "launchctl", "codesign", "spctl", "xattr", "plutil",
        "osascript", "pbcopy", "pbpaste", "mdfind", "mdls", "ditto", "hdiutil", "diskutil", "tar", "unzip", "gzip",
        "gunzip", "ps", "pkill", "killall", "pgrep", "lsof", "sed", "awk", "gawk", "tee", "vim", "vi", "nvim", "nano",
        "emacs", "rm", "cp", "mv", "ln", "chflags", "xargs", "jq", "yq", "wc", "uniq", "diff", "patch", "env",
        "which", "whereis", "whoami", "uname", "sw_vers", "sysctl", "ifconfig", "ping", "traceroute", "nslookup",
        "dig", "netstat", "nc", "telnet", "systemctl", "journalctl", "apt", "apt-get", "yum", "dnf", "pacman",
        "zsh", "bash", "sh", "fish", "chsh", "crontab", "shasum", "sha256sum", "sha1sum", "md5", "md5sum", "openssl",
        "base64", "hexdump", "xxd", "strings", "otool", "nm", "lipo", "install_name_tool", "dscl", "scutil",
        "networksetup", "pmset", "caffeinate", "softwareupdate", "tmutil", "mas", "conda", "poetry", "uv", "pytest",
        "make", "go", "kill", "open", "cat", "head", "tail", "find", "touch", "sort", "less", "more", "top", "htop",
        "code", "source", "zip", "du", "df", "file", "stat", "date", "cal", "history", "man", "watch", "time",
    ]
    /// 也是普通英文单词的命令名：只算 +2，需要其他命令特征一起才判定
    static let ambiguousCommands: Set<String> = [
        "make", "go", "kill", "open", "cat", "head", "tail", "find", "touch", "sort", "less", "more", "top", "code",
        "source", "zip", "file", "stat", "date", "history", "man", "watch", "time", "patch", "diff", "su", "which",
        "ping", "echo", "swift", "python", "ruby", "gem", "bundle", "pod", "node", "java", "export", "alias", "tee",
        "nano", "bash", "fish", "dig", "apt", "mas", "poetry", "strings", "cal", "printf", "emacs", "helm", "uv",
    ]
    /// 单独一个词就能判为命令的（不是普通英文单词）
    static let standaloneCommands: Set<String> = [
        "ls", "cd", "pwd", "rg", "git", "brew", "npm", "npx", "pnpm", "yarn", "pip", "pip3", "python3", "xcodebuild",
        "sudo", "ssh", "kubectl", "ifconfig", "htop", "whoami", "uname", "sw_vers", "pbpaste", "pbcopy", "lsof",
        "ps", "df", "du", "env", "printenv", "xcrun", "swiftc", "rustup", "cargo", "gh", "nvim", "vim", "zsh",
    ]
    /// 命令后常见的子命令（模糊命令名 + 子命令 → 再 +1）
    static let subcommands: Set<String> = [
        "build", "test", "run", "install", "clean", "init", "commit", "push", "pull", "status", "checkout", "clone",
        "restart", "exec", "uninstall", "package", "mod", "upgrade", "update", "version", "all", "-m", "-c", "-e",
    ]
    /// 自然语言常用词（出现在引号外时减分）
    static let englishWords: Set<String> = [
        "the", "a", "an", "to", "for", "me", "you", "your", "please", "can", "could", "would", "should", "is", "are",
        "was", "were", "my", "this", "that", "with", "and", "of", "in", "on", "it", "sure", "we", "i", "our",
        "us", "they", "them", "be", "have", "has", "will", "do", "does", "did", "not", "if", "when", "what", "how",
        "why", "there", "here", "some", "any", "all", "out", "about", "at", "by", "from", "so", "just", "let",
    ]

    static let fileExt = #"\.(swift|md|txt|json|py|js|mjs|ts|tsx|jsx|sh|zsh|plist|ya?ml|toml|csv|tsv|log|app|zip|tgz|gz|bz2|xz|dmg|pkg|c|h|m|mm|cpp|hpp|go|rs|java|kt|rb|php|html|css|scss|xml|lock|conf|cfg|ini|env|sql|db|pem|key|crt|ipa|xcodeproj|xcworkspace|entitlements|o|a|dylib|so)$"#

    static let outputPatterns: [String] = [
        #"^\S+\.[A-Za-z0-9]+:\d+(:\d+)?:"#,                                  // path/file.swift:12:5: error …
        #"^(On branch|Your branch is|Changes (not staged|to be committed)|Untracked files|nothing to commit|nothing added to commit|HEAD is now at|Switched to( a new)? branch|Already up to date|Fast-forward|Merge made by)"#,
        #"^\s*(modified|new file|deleted|renamed|both modified|typechange):\s+\S"#,
        #"^(commit [0-9a-f]{7,40}|diff --git |index [0-9a-f]{6,}\.\.[0-9a-f]{6,}|@@ -\d+(,\d+)? \+\d+(,\d+)? @@|\+\+\+ b/|--- a/)"#,
        #"^(fatal|error|warning|hint|remote|npm (ERR!|WARN)|E|W):\s"#,
        #"^(Enumerating|Counting|Compressing|Writing|Receiving|Resolving) (objects|deltas):"#,
        #"^\s*\(use "git "#,
        #"^[dlcbps\-][rwxsStT\-]{9}[@+.]?\s+\d+"#,                           // ls -l
        #"^(zsh|bash|sh|fish|sudo): "#,
        #"^Traceback \(most recent call last\):|^\s*File ".+", line \d+"#,
        #"^\s*at .+\(.+:\d+:\d+\)$"#,                                        // JS 调用栈
        #"^\[\d+/\d+\] (Compiling|Linking|Emitting|Planning|Write)"#,         // swift build 进度
        #"^(Build complete!|Compiling |Linking |Building for )"#,
        #"^total \d+$"#,
        #"^(Author|Commit|Merge):\s+.+<[^<>@\s]+@[^<>\s]+>$"#,                // git log 头
        #"^(Author|Commit)?Date:\s+(Mon|Tue|Wed|Thu|Fri|Sat|Sun) \w{3} \d{1,2} \d\d:\d\d:\d\d \d{4}"#,
    ]

    public static func isCommand(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        var hits = 0
        var continued = false
        for l in lines {
            // 上一行以 \ 结尾：这一行是续行
            if continued || lineScore(l) >= lineThreshold { hits += 1 }
            continued = l.hasSuffix("\\")
        }
        if lines.count == 1 { return hits == 1 }
        return Double(hits) / Double(lines.count) >= 0.5
    }

    public static func lineScore(_ raw: String) -> Int {
        var line = raw.trimmingCharacters(in: .whitespaces)
        var score = 0

        for p in outputPatterns where line.range(of: p, options: .regularExpression) != nil { return 5 }

        // 提示符：$ / % / # / > / ❯ / ➜ 开头，或 user@host dir % 形式
        if let r = line.range(of: #"^([\w.\-]+@[\w.\-]+(:\S*)?\s?(\S+\s)?[$#%]\s+|(\(\S+\)\s)?[$%#>❯➜»]\s+)"#,
                               options: .regularExpression) {
            line = String(line[r.upperBound...])
            score += 2
        }
        // 去掉引号里的内容（git commit -m "fix the bug" 里的英文不算自然语言）
        let unquoted = line.replacingOccurrences(of: #""[^"]*"|'[^']*'"#, with: " Q ", options: .regularExpression)
        var toks = unquoted.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // FOO=bar cmd …
        while let f = toks.first, f.range(of: #"^[A-Z_][A-Z0-9_]*=\S*$"#, options: .regularExpression) != nil {
            score += 3; toks.removeFirst()
        }
        guard let first = toks.first else { return score }

        let cmd = first.hasPrefix("./") || first.hasPrefix("~/") || first.hasPrefix("/") ? "path" : first
        if cmd == "path", toks.count >= 1, first.range(of: #"^(\.{1,2}|~)?/[\w.\-/]+$"#, options: .regularExpression) != nil {
            score += 2                                   // ./build.sh、/usr/bin/foo --x
        } else if strongCommands.contains(cmd) || standaloneCommands.contains(cmd) {
            let ambiguous = ambiguousCommands.contains(cmd)
            if toks.count == 1 && score == 0 {
                score += standaloneCommands.contains(cmd) ? 3 : 0     // 单独一个 “swift”“open”：当普通单词
            } else {
                score += ambiguous ? 2 : 3
                if ambiguous, toks.count >= 2, subcommands.contains(toks[1]) { score += 1 }
            }
        }

        var flags = 0, ops = 0, paths = 0, vars = 0, assigns = 0, plain = 0, english = 0
        for (i, t) in toks.enumerated() {
            if t.range(of: #"^--?[A-Za-z0-9][\w\-]*(=\S*)?$"#, options: .regularExpression) != nil { flags += 1; continue }
            if ["|", "||", "&&", ">", ">>", "<", "2>", "2>&1", "&>", "|&", "&"].contains(t) || t.hasPrefix("2>") { ops += 1; continue }
            if t.hasSuffix(";") && i < toks.count - 1 { ops += 1 }
            if t.contains("$(") || t.contains("`") || t.contains("${")
                || t.range(of: #"\$[A-Za-z_]"#, options: .regularExpression) != nil { vars += 1 }
            if t.hasPrefix("~/") || t.hasPrefix("./") || t.hasPrefix("../") || t == "." || t == ".." || t == "~"
                || (t.hasPrefix("/") && t.count > 1) || t.contains("*")
                || t.range(of: fileExt, options: [.regularExpression, .caseInsensitive]) != nil
                || (t.contains("/") && !t.contains("://") && t.range(of: #"^[\w.\-]+(/[\w.\-]+)+/?$"#, options: .regularExpression) != nil) {
                paths += 1
            }
            if i > 0, t.range(of: #"^[\w.\-]+=\S+$"#, options: .regularExpression) != nil { assigns += 1 }
            let bare = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.?!:;\"'()"))
            if englishWords.contains(bare) { english += 1 }
            if t.range(of: #"^[A-Za-z][a-z']*[,.?!]?$"#, options: .regularExpression) != nil { plain += 1 }
        }
        score += min(flags, 2) * 2 + min(ops, 2) * 2 + min(vars, 2) * 2 + min(paths, 2) + min(assigns, 1)
        if line.hasSuffix("\\") || line.contains("&&") || line.contains("||") { score += 1 }
        if unquoted.contains(" | ") { score += 1 }

        // 自然语言特征
        if let c = first.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(c),
           first.range(of: #"^[A-Z][a-z']+[,.?!]?$"#, options: .regularExpression) != nil { score -= 2 }
        if line.range(of: #"[A-Za-z)'"’][.?!]["')’]*$"#, options: .regularExpression) != nil { score -= 2 }
        score -= min(english, 4)
        // 很多普通单词、几乎没有命令符号：像句子
        if plain >= 6 && flags + ops + vars == 0 { score -= 2 }
        return score
    }
}
