import Foundation

enum VowenState { case unavailable, idle, recording }

/// Polls Vowen's local CLI server, discovered through its server.json file.
final class VowenMonitor: @unchecked Sendable {
    /// STOP_YAPPING_VOWEN_DISCOVERY points at another server.json, for testing.
    static let defaultDiscoveryURL = ProcessInfo.processInfo.environment["STOP_YAPPING_VOWEN_DISCOVERY"]
        .map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vowen/cli/server.json")

    private struct Discovery: Decodable { let port: Int; let token: String? }
    private struct Status: Decodable { let recording: Bool? }

    private let discoveryURL: URL
    private let session: URLSession
    private var discovery: Discovery?

    init(discoveryURL: URL = VowenMonitor.defaultDiscoveryURL) {
        self.discoveryURL = discoveryURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.2
        config.timeoutIntervalForResource = 0.25
        config.connectionProxyDictionary = [:]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: config)
    }

    /// Runs on a background thread until `shouldStop` returns true.
    func run(publish: @escaping (VowenState) -> Void, shouldStop: @escaping () -> Bool) {
        while !shouldStop() {
            let state = read()
            publish(state)
            Thread.sleep(forTimeInterval: state == .unavailable ? 0.1 : 0.025)
        }
    }

    func read() -> VowenState {
        if discovery == nil {
            guard let data = try? Data(contentsOf: discoveryURL),
                  let parsed = try? JSONDecoder().decode(Discovery.self, from: data) else {
                return .unavailable
            }
            discovery = parsed
        }
        guard let found = discovery, (1...65535).contains(found.port),
              let token = found.token, !token.isEmpty,
              let url = URL(string: "http://127.0.0.1:\(found.port)/v1/status") else {
            discovery = nil
            return .unavailable
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 0.2

        let done = DispatchSemaphore(value: 0)
        var result: VowenState = .unavailable
        let task = session.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data, let status = try? JSONDecoder().decode(Status.self, from: data),
                  let recording = status.recording else { return }
            result = recording ? .recording : .idle
        }
        task.resume()
        if done.wait(timeout: .now() + 0.3) == .timedOut {
            task.cancel()
            done.wait()
        }
        if result == .unavailable { discovery = nil }
        return result
    }
}
