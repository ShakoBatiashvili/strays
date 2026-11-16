import Foundation

/// Hides secrets that people pass on command lines (API keys, tokens, passwords) before anything is shown,
/// printed or exported. Errs on the side of hiding.
public enum Redactor {
    public static let mask = "••••"

    /// A flag or variable is secret when its *last* word is one of these ("api-key", "OPENAI_API_KEY", "accessToken"),
    /// so "--token-file", "--max-tokens" and "--passWithNoTests" are not.
    private static let secretLastWords: Set<String> = [
        "key", "apikey", "token", "secret", "password", "passwd", "pass", "pwd", "auth", "credential", "credentials",
        "cookie", "signature", "bearer", "pat", "privatekey", "accesskey", "secretkey", "authorization", "passphrase",
    ]
    private static let secretSuffixes = ["token", "secret", "password", "passwd", "apikey", "accesskey", "secretkey", "privatekey"]
    private static let tokenPrefixes = ["sk-", "sk_live_", "sk_test_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
                                        "github_pat_", "glpat-", "xoxb-", "xoxp-", "xoxa-", "xapp-", "AKIA", "ASIA", "AIza",
                                        "crsr_", "hf_", "npm_", "pypi-", "dop_v1_", "shpat_", "sq0atp-", "SG.", "ya29."]
    /// Tools whose own short flags take a password.
    private static let attachedPasswordTools: Set<String> = ["mysql", "mysqldump", "mysqladmin", "mariadb", "mariadb-dump", "mysqlsh"]
    private static let passwordFlagTools: [String: String] = ["sshpass": "-p", "redis-cli": "-a", "valkey-cli": "-a"]
    private static let userPassTools: Set<String> = ["curl", "wget", "http", "https", "xh"]

    public static func redact(_ text: String) -> String {
        let tokens = redactJSONPairs(text).split(whereSeparator: \.isWhitespace).map(String.init)
        let tools = Set(tokens.map { Recognizer.basename($0) })
        var out: [String] = []
        var maskNextAlways = false   // after "Bearer", "Authorization:", "X-Api-Key:"
        var maskNextValue = false    // after "--password", "-p" for sshpass: masked unless the next token is a flag
        var maskNextPassword = false // after curl's "-u": mask the part after "user:"

        for token in tokens {
            // Already masked (a JSON value): keep it as it is, quotes and brackets included.
            if token.contains(mask) {
                out.append(token)
                maskNextAlways = false; maskNextValue = false; maskNextPassword = false
                continue
            }
            let core = strip(token).lowercased()
            if maskNextAlways {
                out.append(mask)
                // "Authorization: Bearer xyz": the scheme is not the secret, what follows it is.
                maskNextAlways = core == "bearer" || core == "basic" || core == "token"
                if maskNextAlways { out[out.count - 1] = token }
                continue
            }
            if maskNextValue {
                maskNextValue = false
                if !token.hasPrefix("-") || token == "-" { out.append(mask); continue }
            }
            if maskNextPassword {
                maskNextPassword = false
                if let colon = token.firstIndex(of: ":") { out.append(String(token[...colon]) + mask); continue }
            }

            if core == "bearer" || core == "basic" {
                out.append(token)
                maskNextAlways = true
                continue
            }
            if core.hasSuffix(":"), core.count > 1, isSecretName(String(core.dropLast())) {
                out.append(token)
                maskNextAlways = true
                continue
            }

            if token.hasPrefix("-"), token.count > 1 {
                if !tools.isDisjoint(with: attachedPasswordTools), token.hasPrefix("-p"), token.count > 2,
                   !token.hasPrefix("--") {
                    out.append("-p" + mask); continue
                }
                if passwordFlagTools.contains(where: { tools.contains($0.key) && $0.value == token }) {
                    out.append(token); maskNextValue = true; continue
                }
                if !tools.isDisjoint(with: userPassTools), token == "-u" || token == "--user" {
                    out.append(token); maskNextPassword = true; continue
                }
                let body = token.drop { $0 == "-" }
                let dashes = token.prefix(token.count - body.count)
                if let eq = body.firstIndex(of: "=") {
                    let name = String(body[..<eq])
                    let value = String(body[body.index(after: eq)...])
                    let masked = isSecretName(name) ? mask : redactWord(value)
                    out.append(String(dashes) + name + "=" + masked)
                } else {
                    if isSecretName(String(body)) { maskNextValue = true }
                    out.append(token)
                }
                continue
            }
            out.append(redactWord(token))
        }
        return out.joined(separator: " ")
    }

    /// `"password": "…"` and friends inside JSON bodies.
    private static let jsonPair: NSRegularExpression = {
        let names = "password|passwd|secret|token|apikey|api_key|api-key|credential|credentials|private_key|privatekey|authorization|passphrase"
        return try! NSRegularExpression(pattern: "(\"[A-Za-z0-9_\\-]*(?:\(names))\"\\s*:\\s*)\"[^\"]*\"", options: [.caseInsensitive])
    }()

    private static func redactJSONPairs(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return jsonPair.stringByReplacingMatches(in: text, range: range, withTemplate: "$1\"\(mask)\"")
    }

    private static func redactWord(_ word: String) -> String {
        // NAME=value, possibly quoted ("API_KEY=…").
        if let eq = word.firstIndex(of: "="), !word.contains("://"), !word.contains("?") {
            let name = String(word[..<eq]).trimmingCharacters(in: CharacterSet.alphanumerics.union(["_"]).inverted)
            if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), isSecretName(name) {
                let closing = word.last.map { "\"'`".contains($0) ? String($0) : "" } ?? ""
                return String(word[...eq]) + mask + closing
            }
        }
        var w = word
        // scheme://userinfo@host: the whole userinfo goes (a token is often the user part).
        if let schemeEnd = w.range(of: "://") {
            let rest = w[schemeEnd.upperBound...]
            let hostEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
            if let at = rest[..<hostEnd].lastIndex(of: "@"), at > schemeEnd.upperBound {
                w.replaceSubrange(schemeEnd.upperBound..<at, with: mask)
            }
        }
        // ?token=…&key=…
        if let q = w.firstIndex(of: "?") {
            let query = w[w.index(after: q)...].split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
                guard let eq = pair.firstIndex(of: "=") else { return String(pair) }
                let name = String(pair[..<eq])
                return isSecretName(name) ? name + "=" + mask : String(pair)
            }
            w = String(w[...q]) + query.joined(separator: "&")
        }
        if looksLikeToken(strip(w)) { return mask }
        return w
    }

    /// Words of a name, splitting camelCase too: "apiKey" -> ["api", "key"], "OPENAI_API_KEY" -> ["openai", "api", "key"].
    static func words(_ name: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var previous: Character?
        for ch in name {
            if !(ch.isLetter || ch.isNumber) {
                if !current.isEmpty { parts.append(current) }
                current = ""
            } else if ch.isUppercase, let p = previous, p.isLowercase {
                parts.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
            previous = ch
        }
        if !current.isEmpty { parts.append(current) }
        return parts.map { $0.lowercased() }
    }

    static func isSecretName(_ name: String) -> Bool {
        guard let last = words(name).last else { return false }
        return secretLastWords.contains(last) || secretSuffixes.contains { last.hasSuffix($0) && last != "tokens" }
    }

    static func looksLikeToken(_ word: String) -> Bool {
        if tokenPrefixes.contains(where: { word.hasPrefix($0) && word.count >= $0.count + 12 }) { return true }
        // JWT: three base64url parts, the first starting with eyJ.
        if word.hasPrefix("eyJ"), word.split(separator: ".").count == 3, word.count > 30 { return true }
        // UUIDs (session ids) and 40-character git commit hashes are identifiers, not secrets.
        if isUUID(word) { return false }
        if word.count == 40, word.allSatisfy(\.isHexDigit) { return false }
        // Long opaque strings with letters and digits mixed (random keys, hex secrets). Paths and module
        // names contain "/" or "." and are left alone.
        guard word.count >= 32, !word.contains("/"), !word.contains(".") else { return false }
        let allowed = word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "+" || $0 == "=" }
        let digits = word.filter(\.isNumber).count
        let letters = word.filter(\.isLetter).count
        return allowed && digits >= 4 && letters >= 4
    }

    private static func isUUID(_ word: String) -> Bool {
        let groups = word.split(separator: "-", omittingEmptySubsequences: false)
        return groups.map(\.count) == [8, 4, 4, 4, 12] && groups.allSatisfy { $0.allSatisfy(\.isHexDigit) }
    }

    /// Quotes and brackets around a token, for looking at what is inside.
    private static func strip(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{},;"))
    }
}
