import Foundation

/// Hides secrets that people pass on command lines (API keys, tokens, passwords) before
/// anything is shown, printed or exported. Errs on the side of hiding.
public enum Redactor {
    public static let mask = "••••"

    /// Whole words in a flag or variable name that mean "the value is a secret" ("api-key", "OPENAI_API_KEY", "apiKey").
    private static let secretParts: Set<String> = ["key", "apikey", "token", "secret", "password", "passwd", "pass", "pwd",
                                                   "auth", "credential", "credentials", "cookie", "signature", "bearer", "pat",
                                                   "privatekey", "accesskey", "secretkey"]
    /// Anywhere in the name.
    private static let secretFragments = ["token", "secret", "password", "apikey", "credential"]
    private static let tokenPrefixes = ["sk-", "sk_live_", "sk_test_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
                                        "github_pat_", "glpat-", "xoxb-", "xoxp-", "xoxa-", "xapp-", "AKIA", "ASIA", "AIza",
                                        "crsr_", "hf_", "npm_", "pypi-", "dop_v1_", "shpat_", "sq0atp-", "SG."]

    public static func redact(_ text: String) -> String {
        var tokens = text.components(separatedBy: " ")
        var maskNext = false
        for i in tokens.indices {
            let token = tokens[i]
            if maskNext, !token.isEmpty, !token.hasPrefix("-") {
                tokens[i] = mask
                maskNext = false
                continue
            }
            maskNext = false
            if token.hasPrefix("-") {
                let body = token.drop { $0 == "-" }
                if let eq = body.firstIndex(of: "=") {
                    if isSecretName(String(body[..<eq])) { tokens[i] = String(token[...eq]) + mask }
                } else if isSecretName(String(body)) {
                    maskNext = true
                }
                continue
            }
            tokens[i] = redactWord(token)
        }
        return tokens.joined(separator: " ")
    }

    private static func redactWord(_ word: String) -> String {
        // NAME=value
        if let eq = word.firstIndex(of: "="), !word.contains("://"), !word.contains("?") {
            let name = String(word[..<eq])
            if name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), isSecretName(name) {
                return String(word[...eq]) + mask
            }
        }
        var w = word
        // scheme://user:password@host
        if let schemeEnd = w.range(of: "://"), let at = w[schemeEnd.upperBound...].firstIndex(of: "@") {
            let userInfo = w[schemeEnd.upperBound..<at]
            if let colon = userInfo.firstIndex(of: ":") {
                w.replaceSubrange(w.index(after: colon)..<at, with: mask)
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
        if looksLikeToken(w) { return mask }
        return w
    }

    static func isSecretName(_ name: String) -> Bool {
        let parts = name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if parts.contains(where: secretParts.contains) { return true }
        let joined = parts.joined()
        return secretFragments.contains { joined.contains($0) }
    }

    static func looksLikeToken(_ word: String) -> Bool {
        if tokenPrefixes.contains(where: { word.hasPrefix($0) && word.count >= $0.count + 12 }) { return true }
        // JWT: three base64url parts, the first starting with eyJ.
        if word.hasPrefix("eyJ"), word.split(separator: ".").count == 3, word.count > 30 { return true }
        // Long opaque strings with letters and digits mixed (hex digests, random keys). Paths and
        // module names contain "/" or "." and are left alone.
        guard word.count >= 32, !word.contains("/"), !word.contains(".") else { return false }
        let allowed = word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "+" || $0 == "=" }
        let digits = word.filter(\.isNumber).count
        let letters = word.filter(\.isLetter).count
        return allowed && digits >= 4 && letters >= 4
    }
}
