import Foundation
import Combine

@MainActor
final class JobStore: ObservableObject {
    @Published private(set) var jobs: [Job] = []

    private var api: APIClient?
    private var pollTask: Task<Void, Never>?

    func configure(api: APIClient) {
        self.api = api
    }

    func refresh() async {
        guard let api else { return }
        jobs = (try? await api.fetchJobs()) ?? jobs
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                let hasActive = jobs.contains(where: \.isActive)
                try? await Task.sleep(for: .seconds(hasActive ? 2 : 10))
            }
        }
    }

    func cancel(id: String) async throws {
        try await api?.cancelJob(id: id)
        await refresh()
    }

    func delete(id: String) async throws {
        try await api?.deleteJob(id: id)
        jobs.removeAll { $0.id == id }
    }

    func fetchJob(id: String) async throws -> Job {
        guard let api else { throw APIError.serverError("Nicht konfiguriert") }
        return try await api.fetchJob(id: id)
    }

    func downloadText(jobId: String, format: String) async throws -> String {
        guard let api else { throw APIError.serverError("Nicht konfiguriert") }
        return try await api.downloadText(jobId: jobId, format: format)
    }
}
