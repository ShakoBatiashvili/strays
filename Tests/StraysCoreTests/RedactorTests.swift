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
        ("psql postgres://admin:s3cr3t@localhost:5432/app", "psql postgres://admin:••••@localhost:5432/app"),
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
