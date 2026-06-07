import SwiftUI
import AVFoundation

struct RecordView: View {
    @EnvironmentObject var recorder: AudioRecorder
    @EnvironmentObject var queue: UploadQueue
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var jobStore: JobStore

    @State private var prompt: String = AppSettings.defaultPrompt
    @State private var selectedModel: String = "large-v3"
    @State private var showPromptEditor = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 32) {
                    // Waveform visualizer
                    WaveformView(level: recorder.level, isRecording: recorder.isRecording)
                        .frame(height: 80)
                        .padding(.horizontal)

                    // Duration
                    Text(formatDuration(recorder.duration))
                        .font(.system(size: 56, weight: .thin, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(recorder.isRecording ? .red : .secondary)

                    // Record button
                    Button {
                        Task { await toggleRecording() }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(recorder.isRecording ? Color.red : Color.indigo)
                                .frame(width: 88, height: 88)
                                .shadow(color: recorder.isRecording ? .red.opacity(0.4) : .indigo.opacity(0.4), radius: 16)
                            Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.white)
                        }
                    }
                    .scaleEffect(recorder.isRecording ? 1.08 : 1.0)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                               value: recorder.isRecording)

                    Text(recorder.isRecording ? "Tippen zum Stoppen" : "Tippen zum Aufnehmen")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Input source (BT headphones / mic)
                    Label(recorder.inputName,
                          systemImage: recorder.inputIsBluetooth ? "airpods" : "mic")
                        .font(.caption2)
                        .foregroundStyle(recorder.inputIsBluetooth ? .indigo : .secondary)

                    // Settings strip
                    VStack(spacing: 0) {
                        // Model picker
                        Picker("Modell", selection: $selectedModel) {
                            ForEach(settings.availableModels, id: \.self) { m in
                                Text(m).tag(m)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.horizontal)

                        Divider()

                        // Prompt
                        Button {
                            showPromptEditor = true
                        } label: {
                            HStack {
                                Image(systemName: "text.quote")
                                Text("Fachvokabular")
                                Spacer()
                                Text(prompt.prefix(30) + (prompt.count > 30 ? "…" : ""))
                                    .lineLimit(1)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.quaternary)
                            }
                            .padding()
                            .foregroundStyle(.primary)
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)

                    // Offline indicator
                    if !queue.isOnline {
                        Label("Offline – Aufnahmen werden gespeichert", systemImage: "wifi.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if let err = errorMessage {
                        Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
                    }

                    Spacer()
                }
                .padding(.top, 32)
            }
            .navigationTitle("Aufnahme")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPromptEditor) {
                PromptEditorView(prompt: $prompt)
            }
            .onAppear {
                selectedModel = settings.defaultModel
                prompt = settings.defaultPrompt
            }
        }
    }

    private func toggleRecording() async {
        errorMessage = nil
        if recorder.isRecording {
            guard let url = recorder.stopRecording() else { return }
            let name = url.lastPathComponent
            queue.enqueue(fileURL: url, filename: name, prompt: prompt, model: selectedModel)
            jobStore.startPolling()
        } else {
            do {
                try await recorder.startRecording()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t / 60), s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: – Waveform

struct WaveformView: View {
    let level: Float   // -160…0
    let isRecording: Bool

    private var normalizedLevel: CGFloat {
        CGFloat(max(0, min(1, (level + 60) / 60)))
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<24, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(isRecording ? Color.red : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: barHeight(for: i))
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        guard isRecording else { return 4 }
        let center = 12.0
        let distance = abs(Double(index) - center) / center
        let noise = CGFloat.random(in: 0.5...1.0)
        return max(4, normalizedLevel * 72 * (1 - distance * 0.4) * noise)
    }
}

// MARK: – Prompt editor

struct PromptEditorView: View {
    @Binding var prompt: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $prompt)
                .padding()
                .navigationTitle("Fachvokabular")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { dismiss() }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Zurücksetzen") {
                            prompt = AppSettings.defaultPrompt
                        }
                    }
                }
        }
    }
}
