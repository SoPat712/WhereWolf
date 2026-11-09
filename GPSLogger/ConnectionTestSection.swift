import SwiftUI

struct ConnectionTestSection: View {
    var enabled = true
    var prepare: () -> Bool = { true }
    @State private var preparationFailed = false
    @State private var test = ConnectionTestModel()

    var body: some View {
        Section {
            Button("Test Connection") {
                preparationFailed = !prepare()
                guard !preparationFailed else { return }
                Task { await test.run() }
            }
            .disabled(!enabled || test.busy)
            .accessibilityLabel("Test Connection")
            .accessibilityIdentifier("wherewolf.testConnection")
            if preparationFailed { Text("Couldn’t save server edits. Check the URL, headers and Keychain access, then try again.").foregroundStyle(.orange) }
            if test.busy { ProgressView("Getting Location and Testing…") }
            if let result = test.result {
                Text(result.message)
                    .foregroundStyle(isSuccess(result) ? Color.green : .orange)
                    .accessibilityIdentifier("wherewolf.testConnection.result")
            }
        } footer: {
            Text("Saves these edits and sends your current location as a real point now, even on cellular. The queue, history, trips and send statistics stay untouched.")
        }
    }
    private func isSuccess(_ result: ConnectionTestResult) -> Bool {
        if case .success = result { return true }; return false
    }
}
