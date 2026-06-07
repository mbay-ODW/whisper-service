import SwiftUI

@main
struct WhisperMemoApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var jobStore = JobStore()
    @StateObject private var queue    = UploadQueue()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(recorder)
                .environmentObject(jobStore)
                .environmentObject(queue)
                .task { configureAPI() }
                .onChange(of: settings.serverURL) { _, _ in configureAPI() }
                .onChange(of: settings.appToken)  { _, _ in configureAPI() }
        }
    }

    private func configureAPI() {
        guard !settings.serverURL.isEmpty, !settings.appToken.isEmpty,
              let url = URL(string: settings.serverURL) else { return }
        let client = APIClient(baseURL: url, token: settings.appToken)
        jobStore.configure(api: client)
        queue.configure(api: client)
    }
}

struct RootView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        if settings.serverURL.isEmpty || settings.appToken.isEmpty {
            NavigationStack {
                SettingsView()
                    .navigationTitle("Einrichtung")
            }
        } else {
            MainTabView()
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var jobStore: JobStore

    var body: some View {
        TabView {
            RecordView()
                .tabItem { Label("Aufnahme", systemImage: "mic.circle.fill") }

            JobListView()
                .tabItem { Label("Aufträge", systemImage: "list.bullet.clipboard") }

            NavigationStack { SettingsView() }
                .tabItem { Label("Einstellungen", systemImage: "gearshape") }
        }
        .onAppear { jobStore.startPolling() }
    }
}
