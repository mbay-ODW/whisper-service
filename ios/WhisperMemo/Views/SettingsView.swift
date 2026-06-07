import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var jobStore: JobStore

    @State private var serverURL = ""
    @State private var appToken  = ""

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("URL") {
                    TextField("https://whisper.example.com", text: $serverURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section {
                LabeledContent("App-Token") {
                    SecureField("Token eingeben", text: $appToken)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Authentifizierung")
            } footer: {
                Text("Token im Web-UI unter \"App-Tokens\" erstellen.")
            }

            Section("Modell") {
                Picker("Standard-Modell", selection: $settings.defaultModel) {
                    ForEach(settings.availableModels, id: \.self) { m in
                        Text(m).tag(m)
                    }
                }
            }

            Section {
                NavigationLink {
                    StatsView()
                } label: {
                    Label("Statistik & Speicher", systemImage: "chart.bar.doc.horizontal")
                }
            }

            Section {
                Button("Speichern") { save() }
                    .disabled(serverURL.isEmpty || appToken.isEmpty)
            }
        }
        .navigationTitle("Einstellungen")
        .onAppear {
            serverURL = settings.serverURL
            appToken  = settings.appToken
        }
    }

    private func save() {
        var url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.hasPrefix("http") { url = "https://" + url }
        settings.serverURL = url
        settings.appToken  = appToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
