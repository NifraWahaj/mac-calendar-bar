import Foundation

/// Google OAuth configuration.
///
/// You can supply credentials in any of these ways (checked in this order):
///   1. Environment variables `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`
///   2. `~/.config/calendarbar/.env`
///   3. `credentials.env` inside the app bundle (build-app.sh copies ./.env there)
///   4. The hardcoded constants below
///
/// `.env` files are `KEY=VALUE` per line. Keys are matched loosely, so all of
/// these work: `GOOGLE_CLIENT_ID`, `CLIENT_ID`, `Client ID`, `client-id`.
enum AppConfig {

    // MARK: - Paste your credentials here (or leave the placeholders and use .env)

    static let hardcodedClientID = "YOUR_CLIENT_ID"
    static let hardcodedClientSecret = "YOUR_CLIENT_SECRET"

    // MARK: - Resolved values

    static let clientID: String = resolve(
        aliases: ["GOOGLECLIENTID", "CLIENTID", "GOOGLEOAUTHCLIENTID"],
        fallback: hardcodedClientID
    )

    /// Optional. Google "Desktop app" clients are issued a secret and their token
    /// endpoint normally requires it even when using PKCE. If it is absent we still
    /// attempt the PKCE-only exchange and surface a clear error if Google rejects it.
    static let clientSecret: String? = {
        let value = resolve(
            aliases: ["GOOGLECLIENTSECRET", "CLIENTSECRET", "GOOGLEOAUTHCLIENTSECRET"],
            fallback: hardcodedClientSecret
        )
        if value.isEmpty || value == "YOUR_CLIENT_SECRET" { return nil }
        return value
    }()

    static var hasClientID: Bool {
        !clientID.isEmpty && clientID != "YOUR_CLIENT_ID"
    }

    // MARK: - OAuth / API endpoints

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    static let calendarAPIBase = URL(string: "https://www.googleapis.com/calendar/v3/")!

    static let scopes = [
        "openid",
        "email",
        "https://www.googleapis.com/auth/calendar.readonly",
        // Read/write is required to mark a task complete; there is no readonly Tasks scope
        // that also allows updates.
        "https://www.googleapis.com/auth/tasks"
    ]

    static let tasksAPIBase = URL(string: "https://tasks.googleapis.com/tasks/v1/")!

    /// How often the background timer re-syncs.
    static let refreshInterval: TimeInterval = 10 * 60

    // MARK: - .env parsing

    private static func resolve(aliases: [String], fallback: String) -> String {
        for alias in aliases {
            if let value = ProcessInfo.processInfo.environment[alias], !value.isEmpty {
                return value
            }
        }
        for alias in aliases {
            if let value = dotEnv[alias], !value.isEmpty {
                return value
            }
        }
        return fallback
    }

    /// Merged contents of every discovered `.env`, with normalized keys.
    private static let dotEnv: [String: String] = {
        var merged: [String: String] = [:]
        for url in envFileCandidates.reversed() {
            for (key, value) in parseEnv(at: url) {
                merged[key] = value
            }
        }
        return merged
    }()

    private static var envFileCandidates: [URL] {
        var urls: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        urls.append(home.appendingPathComponent(".config/calendarbar/.env"))
        if let bundled = Bundle.main.url(forResource: "credentials", withExtension: "env") {
            urls.append(bundled)
        }
        // Convenience for `swift run` from the repo root.
        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".env"))
        return urls
    }

    private static func parseEnv(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = normalize(String(line[line.startIndex..<separator]))
            var value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, let last = value.last,
               first == last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    /// `Client ID` / `client-id` / `GOOGLE_CLIENT_ID` all collapse to `CLIENTID`-style keys.
    private static func normalize(_ key: String) -> String {
        key.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}
