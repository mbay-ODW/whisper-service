import SwiftUI

struct JobListView: View {
    @EnvironmentObject var jobStore: JobStore
    @EnvironmentObject var queue: UploadQueue

    var body: some View {
        NavigationStack {
            Group {
                if jobStore.jobs.isEmpty && queue.pending.isEmpty {
                    ContentUnavailableView(
                        "Keine Aufträge",
                        systemImage: "tray",
                        description: Text("Nimm ein Memo auf, es erscheint hier")
                    )
                } else {
                    List {
                        // Offline queue
                        if !queue.pending.isEmpty {
                            Section("Warte auf Verbindung") {
                                ForEach(queue.pending) { item in
                                    QueuedRow(item: item)
                                }
                            }
                        }

                        // Server jobs
                        let active = jobStore.jobs.filter(\.isActive)
                        let done   = jobStore.jobs.filter { !$0.isActive }

                        if !active.isEmpty {
                            Section("Läuft") {
                                ForEach(active) { job in
                                    JobRow(job: job)
                                }
                            }
                        }

                        if !done.isEmpty {
                            Section("Abgeschlossen") {
                                ForEach(done) { job in
                                    NavigationLink(destination: TranscriptView(job: job)) {
                                        JobRow(job: job)
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                        if let text = job.full_text, !text.isEmpty {
                                            ShareLink(
                                                item: text,
                                                subject: Text(job.filename),
                                                message: Text("Transkript: \(job.filename)")
                                            ) {
                                                Label("Teilen", systemImage: "square.and.arrow.up")
                                            }
                                            .tint(.indigo)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .refreshable { await jobStore.refresh() }
                }
            }
            .navigationTitle("Aufträge")
            .toolbar {
                if !queue.isOnline {
                    ToolbarItem(placement: .topBarTrailing) {
                        Label("Offline", systemImage: "wifi.slash")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
            }
        }
        .task { await jobStore.refresh() }
    }
}

// MARK: – Job row

struct JobRow: View {
    let job: Job
    @EnvironmentObject var jobStore: JobStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.filename)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                StatusBadge(status: job.status)
            }

            if job.isActive {
                ProgressView(value: Double(job.progress) / 100)
                    .tint(job.status == "processing" ? .indigo : .secondary)
            }

            HStack {
                if let dur = job.duration {
                    Text("\(Int(dur))s")
                }
                if let m = job.model { Text(m) }
                Spacer()
                if job.isActive {
                    Button("Abbrechen", role: .destructive) {
                        Task { try? await jobStore.cancel(id: job.id) }
                    }
                    .font(.caption)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let err = job.error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

struct QueuedRow: View {
    let item: QueuedUpload
    @EnvironmentObject var queue: UploadQueue

    var body: some View {
        HStack {
            Image(systemName: item.lastError != nil ? "exclamationmark.circle" : "arrow.up.circle")
                .foregroundStyle(item.lastError != nil ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename).font(.subheadline)
                if let err = item.lastError {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text(queue.isOnline ? "Wird hochgeladen…" : "Wartet auf Verbindung")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if item.retryCount > 0 {
                    Text("Versuche: \(item.retryCount)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if item.lastError != nil {
                Button {
                    queue.remove(id: item.id)
                } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                Button {
                    Task { await queue.processQueue() }
                } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.indigo)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case "queued":     return "Warteschlange"
        case "processing": return "Läuft"
        case "done":       return "Fertig"
        case "error":      return "Fehler"
        case "cancelled":  return "Abgebrochen"
        default:           return status
        }
    }

    private var color: Color {
        switch status {
        case "done":    return .green
        case "error":   return .red
        case "processing": return .indigo
        case "cancelled":  return .secondary
        default:        return .blue
        }
    }
}
