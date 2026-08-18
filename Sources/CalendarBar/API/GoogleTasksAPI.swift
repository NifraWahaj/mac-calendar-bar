import Foundation

/// Thin wrapper over the Google Tasks v1 REST API (a separate service from Calendar,
/// tasks.googleapis.com, with its own scope and its own object model).
struct GoogleTasksAPI {

    let tokenProvider: (_ forceRefresh: Bool) async throws -> String

    private var session: URLSession { .shared }

    func fetchTaskLists() async throws -> [RawTaskList] {
        var lists: [RawTaskList] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "maxResults", value: "100")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: TaskListsResponse = try await get(path: "users/@me/lists", query: query)
            lists.append(contentsOf: page.items ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil
        return lists
    }

    /// Only incomplete tasks: `showCompleted=false` also implies not returning hidden
    /// (already-completed-and-cleared) tasks, which is what the popover wants to show.
    func fetchTasks(taskListID: String) async throws -> [RawTask] {
        var tasks: [RawTask] = []
        var pageToken: String?
        repeat {
            var query = [
                URLQueryItem(name: "maxResults", value: "100"),
                URLQueryItem(name: "showCompleted", value: "false"),
                URLQueryItem(name: "showHidden", value: "false")
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: TasksResponse = try await get(
                path: "lists/\(GoogleCalendarAPI.encodePathSegment(taskListID))/tasks",
                query: query
            )
            tasks.append(contentsOf: page.items ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil
        return tasks
    }

    /// Marks a task completed. Google clears `needsAction` tasks off the default view once
    /// completed, so no explicit "uncomplete" affordance is offered in the popover.
    func completeTask(taskListID: String, taskID: String) async throws {
        let body = ["status": "completed"]
        try await patch(
            path: "lists/\(GoogleCalendarAPI.encodePathSegment(taskListID))"
                + "/tasks/\(GoogleCalendarAPI.encodePathSegment(taskID))",
            body: body
        )
    }

    // MARK: - Transport

    private func get<T: Decodable>(path: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(url: AppConfig.tasksAPIBase, resolvingAgainstBaseURL: false)!
        let base = AppConfig.tasksAPIBase.path
        components.percentEncodedPath = (base.hasSuffix("/") ? base : base + "/") + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw GoogleCalendarAPI.APIError.google(status: 0, reason: nil,
                                                     message: "Could not build a request URL for \(path)")
        }
        return try await perform(url: url, method: "GET", body: nil, forceRefresh: false)
    }

    private func patch(path: String, body: [String: String]) async throws {
        var components = URLComponents(url: AppConfig.tasksAPIBase, resolvingAgainstBaseURL: false)!
        let base = AppConfig.tasksAPIBase.path
        components.percentEncodedPath = (base.hasSuffix("/") ? base : base + "/") + path
        guard let url = components.url else {
            throw GoogleCalendarAPI.APIError.google(status: 0, reason: nil,
                                                     message: "Could not build a request URL for \(path)")
        }
        let payload = try JSONEncoder().encode(body)
        let _: EmptyResponse = try await perform(url: url, method: "PATCH", body: payload, forceRefresh: false)
    }

    private func perform<T: Decodable>(url: URL, method: String, body: Data?,
                                        forceRefresh: Bool) async throws -> T {
        let token = try await tokenProvider(forceRefresh)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        switch status {
        case 200, 204:
            if data.isEmpty, let empty = EmptyResponse() as? T { return empty }
            return try JSONDecoder().decode(T.self, from: data)
        case 401:
            if !forceRefresh {
                return try await perform(url: url, method: method, body: body, forceRefresh: true)
            }
            throw GoogleCalendarAPI.APIError.unauthorized
        default:
            let message = String(decoding: data.prefix(300), as: UTF8.self)
            throw GoogleCalendarAPI.APIError.google(status: status, reason: nil, message: message)
        }
    }
}

/// Used only to satisfy the generic decode path for PATCH responses we don't read.
private struct EmptyResponse: Decodable {}
