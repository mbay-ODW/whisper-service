import Foundation

struct ServerConfig: Decodable {
    let model_default: String
    let models: [String]
}

struct UploadResponse: Decodable {
    struct JobRef: Decodable { let id: String; let filename: String }
    let jobs: [JobRef]
}

struct Job: Decodable, Identifiable {
    let id: String
    let status: String
    let progress: Int
    let filename: String
    let model: String?
    let created_at: Double
    let finished_at: Double?
    let error: String?
    let segments: [Segment]?
    let full_text: String?
    let duration: Double?

    var statusLabel: String {
        switch status {
        case "queued":      return "Warteschlange"
        case "processing":  return "Läuft"
        case "done":        return "Fertig"
        case "error":       return "Fehler"
        case "cancelled":   return "Abgebrochen"
        case "cancelling":  return "Wird abgebrochen"
        default:            return status
        }
    }

    var isDone: Bool { status == "done" }
    var isActive: Bool { ["queued", "processing", "cancelling"].contains(status) }
    var isFailed: Bool { status == "error" || status == "cancelled" }
}

struct Segment: Decodable, Identifiable {
    let id: Int
    let start: Double
    let end: Double
    let text: String

    var timeLabel: String {
        "\(fmtTime(start)) → \(fmtTime(end))"
    }

    private func fmtTime(_ s: Double) -> String {
        let m = Int(s / 60), sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}
