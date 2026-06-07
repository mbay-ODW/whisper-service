import Foundation
import AVFoundation
import Combine

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var duration: TimeInterval = 0
    @Published var permissionDenied = false
    @Published var level: Float = 0   // -160…0 dB, für Visualisierung
    @Published var inputName: String = "Mikrofon"
    @Published var inputIsBluetooth: Bool = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var currentFileURL: URL?
    private(set) var currentFilename: String?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
        updateInputInfo()
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    @objc private nonisolated func handleRouteChange(_ n: Notification) {
        Task { @MainActor [weak self] in self?.updateInputInfo() }
    }

    private func updateInputInfo() {
        let route = AVAudioSession.sharedInstance().currentRoute
        guard let input = route.inputs.first else {
            inputName = "Mikrofon"
            inputIsBluetooth = false
            return
        }
        inputName = input.portName
        switch input.portType {
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
            inputIsBluetooth = true
        default:
            inputIsBluetooth = false
        }
    }

    func startRecording() async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            permissionDenied = true
            throw RecorderError.permissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        // .allowBluetoothHFP    — AirPods/BT-Headsets als Mic-Input (HFP)
        // .allowBluetoothA2DP   — hochwertige Wiedergabe zu BT-Lautsprechern
        // .defaultToSpeaker     — Lautsprecher wenn nichts anderes verbunden
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
        try session.setActive(true)
        updateInputInfo()

        let filename = "memo_\(Int(Date().timeIntervalSince1970)).m4a"
        let url = recordingsDirectory().appendingPathComponent(filename)
        currentFileURL = url
        currentFilename = filename

        let settings: [String: Any] = [
            AVFormatIDKey:            Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:          44100,
            AVNumberOfChannelsKey:    1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.delegate = self
        recorder?.isMeteringEnabled = true
        recorder?.record()

        isRecording = true
        duration = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func stopRecording() -> URL? {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return currentFileURL
    }

    private func tick() {
        duration = recorder?.currentTime ?? 0
        recorder?.updateMeters()
        level = recorder?.averagePower(forChannel: 0) ?? -160
    }

    private func recordingsDirectory() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func deleteRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ r: AVAudioRecorder, successfully flag: Bool) {}
}

enum RecorderError: LocalizedError {
    case permissionDenied
    var errorDescription: String? { "Mikrofon-Zugriff verweigert. Bitte in den Einstellungen erlauben." }
}
