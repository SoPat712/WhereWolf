// TestFlight diagnostics: left out of App Store builds (WHEREWOLF_APP_STORE=YES).
#if WHEREWOLF_TESTFLIGHT_DIAGNOSTICS
import SwiftUI

// TestFlight diagnostics: left out of App Store builds (WHEREWOLF_APP_STORE=YES).
struct DiagnosticsView: View {
    @State private var files: [URL] = []

    var body: some View {
        List {
            Section {
                Text("MetricKit reports stay on this device unless you share them. The latest 100 reports are kept and excluded from backups.")
                if files.isEmpty {
                    Text("No reports yet. iOS delivers metrics periodically and diagnostics after supported events.")
                        .foregroundStyle(.secondary)
                }
                ForEach(files, id: \.self) { file in
                    NavigationLink {
                        DiagnosticReportView(file: file)
                    } label: {
                        Text(file.lastPathComponent).font(.caption).lineLimit(2)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: TestFlightDiagnostics.reportsChanged)) { _ in reload() }
    }

    private func reload() {
        TestFlightDiagnostics.shared.loadReports { files = $0 }
    }
}

// TestFlight diagnostics: left out of App Store builds (WHEREWOLF_APP_STORE=YES).
private struct DiagnosticReportView: View {
    let file: URL
    @State private var text = "Loading report…"

    var body: some View {
        ScrollView {
            Text(text).font(.caption.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle("MetricKit Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ShareLink(item: file) }
        .task { TestFlightDiagnostics.shared.readReport(file) { text = $0 } }
    }
}
#endif
