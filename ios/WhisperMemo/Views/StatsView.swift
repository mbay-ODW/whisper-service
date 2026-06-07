import SwiftUI

struct StatsView: View {
    @EnvironmentObject var queue: UploadQueue
    @EnvironmentObject var jobStore: JobStore

    @State private var stats: StorageStats = StorageStats(
        recordingsBytes: 0, recordingsCount: 0,
        queueBytes: 0, queueCount: 0, totalBytes: 0)
    @State private var clearing = false
    @State private var showClearConfirm = false

    var body: some View {
        Form {
            Section("Speicher") {
                LabeledContent("Gesamt") {
                    Text(StorageStats.formatBytes(stats.totalBytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Lokale Aufnahmen") {
                    Text("\(stats.recordingsCount) · \(StorageStats.formatBytes(stats.recordingsBytes))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Upload-Queue") {
                    Text("\(queue.pending.count) · \(StorageStats.formatBytes(stats.queueBytes))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Section("Aufträge") {
                LabeledContent("Server-Aufträge") {
                    Text("\(jobStore.jobs.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Fertig") {
                    Text("\(jobStore.jobs.filter { $0.status == "done" }.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Mit Fehler") {
                    Text("\(jobStore.jobs.filter { $0.status == "error" }.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("Verwaiste Aufnahmen löschen", systemImage: "trash")
                }
                .disabled(stats.recordingsCount == 0)
            } footer: {
                Text("Entfernt lokale Audiodateien, die nicht in der Upload-Queue stehen. Bereits hochgeladene Aufnahmen werden automatisch nach Erfolg gelöscht.")
            }
        }
        .navigationTitle("Statistik")
        .navigationBarTitleDisplayMode(.inline)
        .task { refresh() }
        .refreshable { refresh() }
        .confirmationDialog(
            "Verwaiste Aufnahmen löschen?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) { clearOrphans() }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private func refresh() {
        var s = StorageStats.compute()
        s = StorageStats(
            recordingsBytes: s.recordingsBytes,
            recordingsCount: s.recordingsCount,
            queueBytes: s.queueBytes,
            queueCount: queue.pending.count,
            totalBytes: s.totalBytes
        )
        stats = s
    }

    private func clearOrphans() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("recordings", isDirectory: true)
        let queued = Set(queue.pending.map { $0.fileURL.lastPathComponent })
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        for url in contents where !queued.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
        refresh()
    }
}
