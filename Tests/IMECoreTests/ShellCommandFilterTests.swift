#if canImport(XCTest)
import XCTest
#endif
import Foundation
@testable import IMECore

final class ShellCommandFilterTests: XCTestCase {
    private func eval(_ t: String) -> ClipboardDecision {
        ClipboardTextFilter.evaluate(text: t, types: ["public.utf8-plain-text"], lastText: nil)
    }

    static let commands: [String] = [
        "ls -la",
        "ls",
        "cd ~/Projects/TranslateIME",
        "$ git status",
        "% swift test",
        "# launchctl list | grep TranslateIME",
        "> npm run dev",
        "dev@macbook YiKey % bash scripts/build.sh",
        "git commit -m \"Fix the clipboard filter for the panel\"",
        "git log --oneline -n 20",
        "git push origin main",
        "brew install ffmpeg",
        "npm install --save-dev typescript",
        "npx create-react-app my-app",
        "pnpm add zod",
        "yarn build",
        "pip install -r requirements.txt",
        "python3 -m venv .venv && source .venv/bin/activate",
        "python main.py --port 8080",
        "swift build -c release",
        "swift test --filter GlossaryTests",
        "xcodebuild -scheme TranslateIME -configuration Release build",
        "open ~/Library/Input\\ Methods",
        "open .",
        "cp build/TranslateIME.app ~/Desktop/",
        "mv old.txt new.txt",
        "rm -rf build",
        "mkdir -p ~/tmp/test",
        "chmod +x scripts/install.sh",
        "sudo chown -R $(whoami) /usr/local/lib",
        "ssh user@192.168.1.10 -p 2222",
        "scp file.zip user@host:/tmp/",
        "curl -fsSL https://example.com/install.sh | bash",
        "wget -O out.tgz https://example.com/a.tgz",
        "docker run -it --rm -p 8080:80 nginx",
        "kubectl get pods -n kube-system",
        "make -j8",
        "make install",
        "cargo build --release",
        "go build ./...",
        "echo $PATH",
        "export PATH=\"$HOME/.local/bin:$PATH\"",
        "FOO=bar swift test",
        "defaults write com.apple.dock autohide -bool true",
        "codesign -dvv /Applications/Safari.app",
        "tar xzf sync.tgz && rm sync.tgz",
        "ps aux | grep TranslateIME",
        "pkill -x TranslateIME",
        "find . -name '*.swift' -type f",
        "grep -rn \"isCodeLike\" Sources",
        "rg --files | head -20",
        "cat README.md",
        "head -n 5 FIXES.md",
        "tail -f ~/Library/Logs/TranslateIME/placement.log",
        "sed -i '' 's/foo/bar/g' file.txt",
        "awk -F'\\t' '{print $1}' data.tsv",
        "ls -la > files.txt 2>&1",
        "./scripts/build.sh",
        "code .",
        "vim ~/.zshrc",
        "kill -9 12345",
        "node server.js",
        "unzip -o TranslateIME-fixed.zip -d out",
        "for f in *.txt; do echo $f; done",
        "docker build \\\n  -t myimage:latest \\\n  --no-cache .",
        "cd ~/Projects/TranslateIME\nswift build\nbash scripts/install.sh",
        "On branch main\nYour branch is up to date with 'origin/main'.\n\nChanges not staged for commit:\n  (use \"git add <file>...\" to update what will be committed)\n\tmodified:   Sources/IMECore/ClipboardWatcher.swift",
        "Sources/IMECore/ClipboardWatcher.swift:67:12: error: cannot find 'ShellCommandDetector' in scope",
        "zsh: command not found: swiftlint",
        "fatal: not a git repository (or any of the parent directories): .git",
        "drwxr-xr-x  5 dev  staff  160 Nov 14 23:16 TranslateIME\n-rw-r--r--  1 dev  staff  267 Nov 14 23:16 glossary.csv",
        "Traceback (most recent call last):\n  File \"main.py\", line 3, in <module>\n    import foo",
        "commit 3f2a9c1d7e\nAuthor: Dev <dev@example.com>\nDate:   Sun Nov 15 06:51:00 2026 -0800",
    ]

    static let english: [String] = [
        "Can you find the git log for me?",
        "Make sure to open the door.",
        "Find the best time to meet next week.",
        "Open the attachment and let me know what you think.",
        "make sure you open the door",
        "find the git log",
        "open the door",
        "Could you send me the report by Friday?",
        "Let's meet at 3pm tomorrow.",
        "The build failed again, can you take a look?",
        "Please install the latest version before the demo.",
        "Echo chamber effects are common on social media.",
        "Python is a great language for data analysis.",
        "Swift is fast and safe.",
        "swift",
        "open",
        "Kill the lights when you leave.",
        "Touch base with the team on Monday.",
        "Head to the office after lunch.",
        "Go ahead and merge the pull request.",
        "Time flies when you are having fun!",
        "Run the tests and push your changes when you're done.",
        "I'll cat-sit for you this weekend.",
        "# Weekly update\nWe shipped the glossary feature and fixed two bugs.",
        "> I think we should wait.\nAgreed, let's wait until Monday.",
        "Sort the files by date, then send them to me.",
        "Watch out for the step.",
        "Thanks again!",
    ]

    func testTerminalCommandsAreIgnored() {
        XCTAssertGreaterThanOrEqual(Self.commands.count, 40)
        var missed: [String] = []
        for c in Self.commands where eval(c) != .ignore(.shellCommand) && eval(c) != .ignore(.codeLike)
            && eval(c) != .ignore(.filePath) {
            missed.append("\(c.prefix(60)) → \(eval(c)) score=\(ShellCommandDetector.lineScore(c))")
        }
        XCTAssertEqual(missed, [], missed.joined(separator: "\n"))
    }

    func testNaturalEnglishStillTranslates() {
        XCTAssertGreaterThanOrEqual(Self.english.count, 20)
        var wrong: [String] = []
        for e in Self.english {
            if case .translate = eval(e) { continue }
            wrong.append("\(e) → \(eval(e)) score=\(ShellCommandDetector.lineScore(e))")
        }
        XCTAssertEqual(wrong, [], wrong.joined(separator: "\n"))
    }

    func testMostCommandsHitShellRuleSpecifically() {
        let hits = Self.commands.filter { ShellCommandDetector.isCommand($0) }.count
        XCTAssertGreaterThanOrEqual(hits, Self.commands.count - 2)
    }

    func testScoringBasics() {
        XCTAssertGreaterThanOrEqual(ShellCommandDetector.lineScore("$ ls -la | grep foo"), 6)
        XCTAssertLessThan(ShellCommandDetector.lineScore("Can you find the git log for me?"), 0)
        XCTAssertTrue(ShellCommandDetector.isCommand("FOO=1 BAR=2 make"))
        XCTAssertFalse(ShellCommandDetector.isCommand("Please run this:\nnpm install\nThen restart the app and tell me if it works."))
    }
}
