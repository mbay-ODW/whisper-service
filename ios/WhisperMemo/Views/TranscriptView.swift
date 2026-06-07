import SwiftUI

struct TranscriptView: View {
    let job: Job
    @EnvironmentObject var jobStore: JobStore
    @State private var fullJob: Job?
    @State private var showTimestamps = false
    @State private var copied = false

    private var displayJob: Job { fullJob ?? job }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Meta
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayJob.filename)
                        .font(.headline)
                    HStack {
                        if let dur = displayJob.duration { Label("\(Int(dur))s", systemImage: "clock") }
                        if let m = displayJob.model { Text(m) }
                        Label(displayJob.statusLabel, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                Divider()

                // Full text
                if let text = displayJob.full_text, !text.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(text)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding(.horizontal)

                        // Timestamp toggle
                        if let segments = displayJob.segments, !segments.isEmpty {
                            Button {
                                withAnimation { showTimestamps.toggle() }
                            } label: {
                                Label(showTimestamps ? "Zeitstempel verbergen" : "Zeitstempel anzeigen",
                                      systemImage: "clock.badge")
                                    .font(.caption)
                            }
                            .padding(.horizontal)

                            if showTimestamps {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(segments) { seg in
                                        HStack(alignment: .top, spacing: 12) {
                                            Text(seg.timeLabel)
                                                .font(.caption2)
                                                .monospacedDigit()
                                                .foregroundStyle(.secondary)
                                                .frame(width: 90, alignment: .leading)
                                            Text(seg.text)
                                                .font(.caption)
                                                .textSelection(.enabled)
                                        }
                                        .padding(.horizontal)
                                        .padding(.vertical, 6)
                                        Divider().padding(.leading)
                                    }
                                }
                                .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                                .padding(.horizontal)
                            }
                        }
                    }
                } else {
                    ProgressView("Lade Transkript…")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .padding(.vertical)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let text = displayJob.full_text, !text.isEmpty {
                    ShareLink(
                        item: text,
                        subject: Text(displayJob.filename),
                        message: Text("Transkript: \(displayJob.filename)")
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }

                Button {
                    copyToClipboard()
                } label: {
                    Label(copied ? "Kopiert!" : "Kopieren",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }

                Menu {
                    Button("TXT herunterladen") { download("txt") }
                    Button("SRT herunterladen") { download("srt") }
                    Button("JSON herunterladen") { download("json") }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
            }
        }
        .task {
            if displayJob.full_text == nil || (displayJob.segments?.isEmpty ?? true) {
                fullJob = try? await jobStore.fetchJob(id: job.id)
            }
        }
    }

    private func copyToClipboard() {
        guard let text = displayJob.full_text else { return }
        UIPasteboard.general.string = text
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { copied = false }
        }
    }

    private func download(_ format: String) {
        Task {
            guard let text = try? await jobStore.downloadText(jobId: job.id, format: format) else { return }
            let filename = "\(URL(fileURLWithPath: job.filename).deletingPathExtension().lastPathComponent).\(format)"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            await MainActor.run {
                let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first?.windows.first?.rootViewController?
                    .present(controller, animated: true)
            }
        }
    }
}
