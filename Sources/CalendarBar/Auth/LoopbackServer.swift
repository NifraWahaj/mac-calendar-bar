import Foundation
import Network

/// A single-shot HTTP listener on 127.0.0.1 used as the OAuth redirect target.
///
/// Google's recommended redirect for installed/desktop apps is a loopback URI, which
/// avoids registering a custom URL scheme and works with the user's default browser.
///
/// Usage is two-phase: `prepare()` binds an ephemeral port (so the redirect URI is known
/// before the browser is opened), then `waitForCallback()` resolves with the query
/// parameters of Google's redirect.
/// Mutable state is confined to `queue` (Network framework delivers every callback there);
/// `prepare()` finishes writing `listener`/`port` before any callback can fire.
final class LoopbackServer: @unchecked Sendable {

    enum ServerError: LocalizedError {
        case couldNotStart(String)
        case timedOut
        case cancelled

        var errorDescription: String? {
            switch self {
            case .couldNotStart(let detail): return "Could not start the local callback server: \(detail)"
            case .timedOut: return "Timed out waiting for the Google sign-in redirect."
            case .cancelled: return "Sign-in was cancelled."
            }
        }
    }

    private let queue = DispatchQueue(label: "com.calendarbar.app.loopback")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var callbackContinuation: CheckedContinuation<[String: String], Error>?
    private var finished = false
    private var prepareResumed = false
    private var timeoutWorkItem: DispatchWorkItem?

    private(set) var port: UInt16 = 0

    var redirectURI: String { "http://127.0.0.1:\(port)" }

    // MARK: - Phase 1: bind

    /// Binds an ephemeral loopback port and returns once the listener is ready.
    func prepare() async throws {
        let listener = try LoopbackServer.makeListener()
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // stateUpdateHandler is delivered on `queue`, so `prepareResumed` needs no
            // extra synchronization.
            listener.stateUpdateHandler = { [self] state in
                guard !prepareResumed else { return }
                switch state {
                case .ready:
                    prepareResumed = true
                    continuation.resume()
                case .failed(let error):
                    prepareResumed = true
                    continuation.resume(throwing: ServerError.couldNotStart(error.localizedDescription))
                case .cancelled:
                    prepareResumed = true
                    continuation.resume(throwing: ServerError.cancelled)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        // The assigned port is only meaningful once the listener is ready.
        guard let assigned = listener.port, assigned.rawValue != 0 else {
            listener.cancel()
            self.listener = nil
            throw ServerError.couldNotStart("no port was assigned")
        }
        port = assigned.rawValue
    }

    // MARK: - Phase 2: wait for the redirect

    /// Resolves with the query parameters of the first request carrying `code` or `error`.
    func waitForCallback(timeout: TimeInterval = 300) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !finished else {
                    continuation.resume(throwing: ServerError.cancelled)
                    return
                }
                callbackContinuation = continuation

                let workItem = DispatchWorkItem { [weak self] in
                    self?.finish(.failure(ServerError.timedOut))
                }
                timeoutWorkItem = workItem
                queue.asyncAfter(deadline: .now() + timeout, execute: workItem)
            }
        }
    }

    func cancel() {
        finish(.failure(ServerError.cancelled))
    }

    // MARK: - Networking

    private static func makeListener() throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Pin to loopback so nothing off-machine can reach the callback.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        if let listener = try? NWListener(using: parameters) {
            return listener
        }
        // Fall back to an unpinned ephemeral port if pinning the local endpoint fails.
        return try NWListener(using: .tcp, on: .any)
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if error != nil {
                connection.cancel()
                return
            }

            let text = String(decoding: buffer, as: UTF8.self)
            if let requestLineEnd = text.range(of: "\r\n") {
                let requestLine = String(text[text.startIndex..<requestLineEnd.lowerBound])
                self.handle(requestLine: requestLine, on: connection)
                return
            }

            if isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private func handle(requestLine: String, on connection: NWConnection) {
        // "GET /?code=...&state=... HTTP/1.1"
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(html: Self.errorPage, on: connection)
            return
        }
        let path = String(parts[1])
        let items = URLComponents(string: "http://127.0.0.1\(path)")?.queryItems ?? []

        var params: [String: String] = [:]
        for item in items {
            if let value = item.value { params[item.name] = value }
        }

        if params["code"] != nil {
            respond(html: Self.successPage, on: connection)
            finish(.success(params))
        } else if let error = params["error"] {
            respond(html: Self.deniedPage(error), on: connection)
            finish(.success(params))
        } else {
            // Favicon or stray request — answer it and keep waiting.
            respond(html: Self.waitingPage, on: connection)
        }
    }

    private func respond(html: String, on connection: NWConnection) {
        let body = Data(html.utf8)
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: text/html; charset=utf-8\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var payload = Data(response.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<[String: String], Error>) {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil

            let continuation = callbackContinuation
            callbackContinuation = nil

            // Give the browser a moment to read the response before tearing down.
            queue.asyncAfter(deadline: .now() + 0.5) { [self] in
                listener?.cancel()
                listener = nil
                connections.forEach { $0.cancel() }
                connections.removeAll()
            }
            continuation?.resume(with: result)
        }
    }

    // MARK: - Browser pages

    private static func page(title: String, message: String, accent: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
        <style>
          :root { color-scheme: light dark; }
          body { margin:0; height:100vh; display:flex; align-items:center; justify-content:center;
                 font: 15px/1.5 -apple-system, system-ui, sans-serif;
                 background:#f5f5f7; color:#1d1d1f; }
          @media (prefers-color-scheme: dark) { body { background:#1c1c1e; color:#f5f5f7; } }
          .card { text-align:center; padding:40px 48px; border-radius:16px; background:rgba(127,127,127,.12); }
          h1 { font-size:19px; margin:0 0 8px; color:\(accent); }
          p { margin:0; opacity:.75; }
        </style></head>
        <body><div class="card"><h1>\(title)</h1><p>\(message)</p></div></body></html>
        """
    }

    private static var successPage: String {
        page(title: "Signed in", message: "You can close this tab and return to Calendar Bar.", accent: "#1e8e5a")
    }

    private static var waitingPage: String {
        page(title: "Waiting for Google…", message: "This window is the Calendar Bar sign-in callback.", accent: "#6e6e73")
    }

    private static var errorPage: String {
        page(title: "Unexpected request", message: "Calendar Bar could not read this callback.", accent: "#c0392b")
    }

    private static func deniedPage(_ error: String) -> String {
        page(title: "Sign-in failed", message: "Google returned: \(error)", accent: "#c0392b")
    }
}
