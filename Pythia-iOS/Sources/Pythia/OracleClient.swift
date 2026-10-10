import Foundation

/// The oracle protocol — a thin HTTP client over the Mac's `limen.rb` daemon.
/// iOS cannot host the Ruby brain (no NSTask), so the companion is a client:
/// the same `POST /aether/invoke` the Mac's cross-context path uses.
public struct OracleClient {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public var baseURL: URL { URL(string: "http://\(host):\(port)")! }

    // MARK: Chat

    /// One oracle turn. `history` carries the per-voice multi-turn memory;
    /// `companion` routes the prompt through a specific pantheon voice.
    public func invoke(
        prompt: String,
        companion: String? = nil,
        history: [[String: String]] = []
    ) async throws -> OracleAnswer {
        var payload: [String: Any] = [
            "prompt": prompt,
            "type": "chat",
            "from_context": "pythia-ios"
        ]
        if let companion, companion != "pythia" {
            payload["active_companions"] = [companion]
        }
        if !history.isEmpty {
            payload["memory"] = history
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("/aether/invoke"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OracleError.http(response as? HTTPURLResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let answer = json["answer"] as? String ?? ""
        return OracleAnswer(
            answer: answer,
            html: json["html"] as? String,
            sourceContext: json["source_context"] as? String
        )
    }

    // MARK: Vox

    public func voices() async throws -> [Voice] {
        let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("/aether/voices"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let raw = json["voices"] as? [[String: Any]] ?? []
        return raw.compactMap { v in
            guard let name = v["name"] as? String else { return nil }
            return Voice(
                name: name,
                locale: v["locale"] as? String ?? "",
                language: v["language"] as? String ?? ""
            )
        }
    }

    public func speak(_ text: String, voice: String?) async throws -> Bool {
        var payload: [String: Any] = ["text": text]
        if let voice { payload["voice"] = voice }

        var request = URLRequest(url: baseURL.appendingPathComponent("/aether/speak"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json["ok"] as? Bool ?? false
    }

    // MARK: Aegis

    public func aegis() async throws -> AegisState {
        let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("/aether/aegis"))
        let decoder = JSONDecoder()
        return try decoder.decode(AegisState.self, from: data)
    }
}

public enum OracleError: Error, LocalizedError {
    case http(HTTPURLResponse?)
    case noAnswer

    public var errorDescription: String? {
        switch self {
        case let .http(response):
            if let code = response?.statusCode, code == 409 { return "The context is busy." }
            return "The oracle did not answer (status \(response?.statusCode ?? -1))."
        case .noAnswer:
            return "The oracle returned no answer."
        }
    }
}
