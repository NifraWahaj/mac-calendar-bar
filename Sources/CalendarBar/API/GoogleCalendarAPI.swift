import Foundation

/// Thin wrapper over the Google Calendar v3 REST API.
struct GoogleCalendarAPI {

    enum APIError: LocalizedError {
        case google(status: Int, reason: String?, message: String)
        case unauthorized

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return "Google rejected the access token. Try signing in again."
            case .google(let status, let reason, let message):
                if let hint = APIError.hint(for: reason, status: status) { return hint }
                return "Google Calendar API error \(status): \(message)"
            }
        }

        /// Turns Google's machine reasons into something the user can act on.
        private static func hint(for reason: String?, status: Int) -> String? {
            switch reason {
            case "accessNotConfigured", "SERVICE_DISABLED":
                return "The Google Calendar API is not enabled for this project. Enable it in the Cloud Console (APIs & Services → Library → Google Calendar API), then hit Retry."
            case "insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT":
                return "This sign-in did not include calendar access. Sign out and sign in again, and accept the calendar permission."
            case "rateLimitExceeded", "userRateLimitExceeded", "quotaExceeded":
                return "Google is rate-limiting requests right now. The next scheduled sync should succeed."
            case "notFound":
                return "A calendar in your list is no longer available. Hit Retry to re-read the calendar list."
            case "forbiddenForServiceAccounts", "dailyLimitExceededUnreg":
                return "The OAuth client is not allowed to read this calendar."
            default:
                return status == 403
                    ? nil // fall through to Google's own wording, which is usually specific
                    : nil
            }
        }
    }

    /// Supplies an access token; `forceRefresh` is used to retry once after a 401.
    let tokenProvider: (_ forceRefresh: Bool) async throws -> String

    private var session: URLSession { .shared }

    // MARK: - Endpoints

    func fetchColors() async throws -> ColorsResponse {
        try await get(path: "colors", query: [])
    }

    func fetchCalendarList() async throws -> [CalendarListEntry] {
        var entries: [CalendarListEntry] = []
        var pageToken: String?
        repeat {
            // colorRgbFormat=true is required for backgroundColor/foregroundColor to be
            // returned at all; without it the response carries only a palette colorId.
            var query = [URLQueryItem(name: "maxResults", value: "250"),
                         URLQueryItem(name: "colorRgbFormat", value: "true"),
                         // Without showHidden, entries the user has hidden in the Google
                         // Calendar list are omitted from the response entirely.
                         URLQueryItem(name: "showHidden", value: "true")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: CalendarListResponse = try await get(path: "users/me/calendarList", query: query)
            entries.append(contentsOf: page.items ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil
        return entries
    }

    func fetchEvents(calendarID: String, timeMin: Date, timeMax: Date) async throws -> [RawEvent] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var events: [RawEvent] = []
        var pageToken: String?
        var pages = 0
        repeat {
            var query = [
                URLQueryItem(name: "timeMin", value: formatter.string(from: timeMin)),
                URLQueryItem(name: "timeMax", value: formatter.string(from: timeMax)),
                // singleEvents expands recurring series into concrete instances.
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "maxResults", value: "250"),
                URLQueryItem(name: "fields", value: Self.eventFields)
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }

            let page: EventsResponse = try await get(
                path: "calendars/\(Self.encodePathSegment(calendarID))/events",
                query: query
            )
            events.append(contentsOf: page.items ?? [])
            pageToken = page.nextPageToken
            pages += 1
        } while pageToken != nil && pages < 8
        return events
    }

    /// Diagnostics: the same events query with **no** `fields` filter, returned verbatim.
    /// Used to prove whether a missing property is Google's omission or our filter's fault.
    func fetchRawEventsBody(calendarID: String, timeMin: Date, timeMax: Date) async throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var components = URLComponents(url: AppConfig.calendarAPIBase, resolvingAgainstBaseURL: false)!
        let base = AppConfig.calendarAPIBase.path
        components.percentEncodedPath = (base.hasSuffix("/") ? base : base + "/")
            + "calendars/\(Self.encodePathSegment(calendarID))/events"
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: timeMin)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: timeMax)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "250")
        ]
        let token = try await tokenProvider(false)
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            let body = String(decoding: data.prefix(200), as: UTF8.self)
            throw APIError.google(status: status, reason: "raw_dump_probe",
                                  message: "HTTP \(status) at \(components.url?.absoluteString ?? "?"): \(body)")
        }
        return data
    }

    private static let eventFields = "nextPageToken,items(id,iCalUID,status,summary,location,colorId,htmlLink,hangoutLink,transparency,start,end,conferenceData(entryPoints(entryPointType,uri)),attendees(email,responseStatus,self),creator(self),organizer(self),eventType,eventLabelId)"

    // MARK: - Transport

    /// Percent-encodes a calendar id for use as a single path segment.
    ///
    /// Calendar ids are email-like (`me@gmail.com`, `en.usa#holiday@group.v.calendar.google.com`),
    /// so `@`, `#` and `%` must all be escaped.
    static func encodePathSegment(_ segment: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    /// `path` must already be percent-encoded. It is assigned to `percentEncodedPath`
    /// rather than going through `appendingPathComponent`, which would double-encode it
    /// (`%40` → `%2540`) and make Google return 404 for every calendar.
    private func get<T: Decodable>(path: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(url: AppConfig.calendarAPIBase, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = AppConfig.calendarAPIBase.path.hasSuffix("/")
            ? AppConfig.calendarAPIBase.path + path
            : AppConfig.calendarAPIBase.path + "/" + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw APIError.google(status: 0, reason: nil, message: "Could not build a request URL for \(path)")
        }

        do {
            return try await perform(url: url, forceRefresh: false)
        } catch APIError.unauthorized {
            return try await perform(url: url, forceRefresh: true)
        }
    }

    private func perform<T: Decodable>(url: URL, forceRefresh: Bool) async throws -> T {
        let token = try await tokenProvider(forceRefresh)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        switch status {
        case 200:
            return try JSONDecoder().decode(T.self, from: data)
        case 401:
            throw APIError.unauthorized
        default:
            throw Self.decodeError(status: status, data: data)
        }
    }

    /// Google's REST errors look like
    /// `{"error":{"code":403,"message":"…","status":"PERMISSION_DENIED","errors":[{"reason":"accessNotConfigured"}]}}`
    private static func decodeError(status: Int, data: Data) -> APIError {
        guard let envelope = try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: data) else {
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            return .google(status: status, reason: nil, message: body)
        }
        let error = envelope.error
        // `errors[].reason` is the classic form; `status` is the newer gRPC-style code.
        let reason = error?.errors?.compactMap(\.reason).first
            ?? error?.details?.compactMap(\.reason).first
            ?? error?.status
        let message = error?.message ?? String(decoding: data.prefix(300), as: UTF8.self)
        return .google(status: status, reason: reason, message: message)
    }
}

private struct GoogleErrorEnvelope: Decodable {
    struct Payload: Decodable {
        struct Item: Decodable {
            let reason: String?
            let message: String?
        }
        let code: Int?
        let message: String?
        let status: String?
        let errors: [Item]?
        let details: [Item]?
    }
    let error: Payload?
}
