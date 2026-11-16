import Testing
@testable import StraysCore

struct RedactorTests {
    static let cases: [(String, String)] = [
        ("node index.js --api-key crsr_FAKE0000FAKE0000FAKE", "node index.js --api-key ••••"),
        ("server --token=abc123def456", "server --token=••••"),
        ("app --password hunter2 --port 3000", "app --password •••• --port 3000"),
        ("--client-secret xyz --verbose", "--client-secret •••• --verbose"),
        ("OPENAI_API_KEY=sk-proj-abcdef0123456789 node x.js", "OPENAI_API_KEY=•••• node x.js"),
        ("GITHUB_TOKEN=whatever npm run release", "GITHUB_TOKEN=•••• npm run release"),
        ("psql postgres://admin:s3cr3t@localhost:5432/app", "psql postgres://••••@localhost:5432/app"),
        // Values of --flag=… are checked too.
        ("celery worker --broker=redis://:hunter2@localhost:6379/0", "celery worker --broker=redis://••••@localhost:6379/0"),
        ("app --database-url=postgres://admin:hunter2@db/app", "app --database-url=postgres://••••@db/app"),
        ("docker run --env=API_KEY=abc123 img", "docker run --env=API_KEY=•••• img"),
        ("docker run -e STRIPE_SECRET=abc img", "docker run -e STRIPE_SECRET=•••• img"),
        // Tokens used as a URL user.
        ("pip install git+https://ghp_abcdefghijklmnop1234@github.com/o/r.git", "pip install git+https://••••@github.com/o/r.git"),
        // Multi-line commands (Claude Code's Bash tool) are split on every kind of whitespace.
        ("cd /x\nOPENAI_API_KEY=sk-abc python app.py", "cd /x OPENAI_API_KEY=•••• python app.py"),
        // Headers.
        ("curl -H Authorization: Bearer ya29.a0AfH6SMBxyz https://x.dev", "curl -H Authorization: Bearer •••• https://x.dev"),
        ("curl -H X-Api-Key: abc123 https://x.dev", "curl -H X-Api-Key: •••• https://x.dev"),
        ("curl -u admin:hunter2 https://x.dev", "curl -u admin:•••• https://x.dev"),
        // Tools with their own password flags.
        ("mysql -u root -phunter2 app", "mysql -u root -p•••• app"),
        ("sshpass -p hunter2 ssh host", "sshpass -p •••• ssh host"),
        ("redis-cli -a hunter2 ping", "redis-cli -a •••• ping"),
        // JSON bodies.
        ("curl -d {\"password\":\"hunter2\",\"user\":\"a\"} https://x.dev", "curl -d {\"password\":\"••••\",\"user\":\"a\"} https://x.dev"),
        ("x {\"access_token\": \"abc\"}", "x {\"access_token\": \"••••\"}"),
        ("curl https://api.example.com/x?token=abc&page=2", "curl https://api.example.com/x?token=••••&page=2"),
        ("tool ghp_0123456789abcdefghijABCDEFGHIJ012345", "tool ••••"),
        ("tool eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl", "tool ••••"),
        ("aws AKIAIOSFODNN7EXAMPLE s3 ls", "aws •••• s3 ls"),
        ("x 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08", "x ••••"),
        // Ordinary commands are left alone.
        ("npm run dev", "npm run dev"),
        ("vite --port 5173 --host 0.0.0.0", "vite --port 5173 --host 0.0.0.0"),
        ("next-server (v15.1.0)", "next-server (v15.1.0)"),
        ("uvicorn app.main:app --reload", "uvicorn app.main:app --reload"),
        ("--keyboard-layout us", "--keyboard-layout us"),
        ("node --max-old-space-size 4096 build.js", "node --max-old-space-size 4096 build.js"),
        ("@modelcontextprotocol/server-filesystem", "@modelcontextprotocol/server-filesystem"),
        ("python -m http.server 8000", "python -m http.server 8000"),
        ("tsx src/server/very_long_module_name_without_digits.ts", "tsx src/server/very_long_module_name_without_digits.ts"),
        ("claude --resume 123e4567-e89b-12d3-a456-426614174000", "claude --resume 123e4567-e89b-12d3-a456-426614174000"),
        ("git checkout 9fceb02d0ae598e95dc970b74767f19372d61af8", "git checkout 9fceb02d0ae598e95dc970b74767f19372d61af8"),
        ("llm --max-tokens 4096 hello", "llm --max-tokens 4096 hello"),
        ("jest --passWithNoTests src/", "jest --passWithNoTests src/"),
        ("serve -p 3000", "serve -p 3000"),
        ("app --token-file /etc/app/token", "app --token-file /etc/app/token"),
        ("app --hotkey ctrl+p", "app --hotkey ctrl+p"),
        ("{\"tokens\": 12, \"author\": \"me\"}", "{\"tokens\": 12, \"author\": \"me\"}"),
    ]

    @Test(arguments: cases)
    func redacts(input: String, expected: String) {
        #expect(Redactor.redact(input) == expected)
    }

    @Test func labelsAreRedacted() {
        let record = ProcRecord(pid: 1, ppid: 1, uid: 501, name: "node", path: "/opt/homebrew/bin/node",
                                arguments: ["node", "index.js", "--api-key", "crsr_FAKE0000FAKE0000FAKE"], startMicros: 0)
        #expect(Recognizer.commandLabel(of: record) == "node index.js --api-key ••••")
    }
}
