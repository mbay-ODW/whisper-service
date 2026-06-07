import Foundation

final class APIClient {
    let baseURL: URL
    private let token: String

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    // MARK: – Config (public, no auth)

    func fetchConfig() async throws -> ServerConfig {
        let req = URLRequest(url: baseURL.appendingPathComponent("api/config"))
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(ServerConfig.self, from: data)
    }

    // MARK: – Health

    /// True if the server's /health endpoint responds with 2xx within timeout.
    /// Authoritative reachability check — preferred over NWPathMonitor alone.
    func ping(timeout: TimeInterval = 5) async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = timeout
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    // MARK: – Upload

    func upload(
        fileURL: URL,
        filename: String,
        prompt: String,
        model: String
    ) async throws -> [String] {
        let url = baseURL.appendingPathComponent("api/transcribe")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        addAuth(to: &req)

        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        let fileData = try Data(contentsOf: fileURL)
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: audio/mp4\r\n\r\n")
        body.append(fileData)
        append("\r\n")

        for (key, value) in [("initial_prompt", prompt), ("model", model)] {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)--\r\n")
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkResponse(resp, data: data)

        struct SingleJob: Decodable { let job_id: String }
        let j = try JSONDecoder().decode(SingleJob.self, from: data)
        return [j.job_id]
    }

    // MARK: – Jobs

    func fetchJobs() async throws -> [Job] {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/jobs"))
        addAuth(to: &req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkResponse(resp, data: data)
        return try JSONDecoder().decode([Job].self, from: data)
    }

    func fetchJob(id: String) async throws -> Job {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/jobs/\(id)"))
        addAuth(to: &req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkResponse(resp, data: data)
        return try JSONDecoder().decode(Job.self, from: data)
    }

    func cancelJob(id: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/jobs/\(id)/cancel"))
        req.httpMethod = "POST"
        addAuth(to: &req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkResponse(resp, data: data)
    }

    func deleteJob(id: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/jobs/\(id)/delete"))
        req.httpMethod = "DELETE"
        addAuth(to: &req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkResponse(resp, data: data)
    }

    // MARK: – Download

    func downloadText(jobId: String, format: String) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/download/\(jobId)/\(format)"))
        addAuth(to: &req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkResponse(resp, data: data)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: – Auth

    private func addAuth(to req: inout URLRequest) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func checkResponse(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw APIError.unauthorized }
        if http.statusCode >= 400 {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "HTTP \(http.statusCode)"
            throw APIError.serverError(msg)
        }
    }
}

enum APIError: LocalizedError {
    case unauthorized
    case serverError(String)
    var errorDescription: String? {
        switch self {
        case .unauthorized:       return "Nicht authentifiziert"
        case .serverError(let m): return m
        }
    }
}
