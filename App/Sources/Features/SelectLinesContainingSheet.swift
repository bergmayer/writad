import SwiftUI

/// Sheet for finding lines that match a substring or regular expression and
/// either selecting them (as a contiguous range from first to last matching
/// line) or filtering the document down to / removing them.
struct SelectLinesContainingSheet: View {

    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var useRegex: Bool = false
    @State private var caseSensitive: Bool = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(useRegex ? "Regular expression" : "Substring", text: $query)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(useRegex ? .body.monospaced() : .body)
                }

                Section("Options") {
                    Toggle("Regular Expression", isOn: $useRegex)
                    Toggle("Case Sensitive", isOn: $caseSensitive)
                }

                Section {
                    Button("Select Lines Containing") {
                        runOrReportError {
                            try CommandActions.selectLinesContaining(
                                query: query,
                                useRegex: useRegex,
                                caseSensitive: caseSensitive
                            )
                        }
                    }
                    .disabled(query.isEmpty)

                    Button("Keep Only Matching Lines") {
                        runOrReportError {
                            try CommandActions.keepLinesMatching(
                                query: query,
                                useRegex: useRegex,
                                caseSensitive: caseSensitive
                            )
                        }
                    }
                    .disabled(query.isEmpty)

                    Button("Remove Matching Lines", role: .destructive) {
                        runOrReportError {
                            try CommandActions.removeLinesMatching(
                                query: query,
                                useRegex: useRegex,
                                caseSensitive: caseSensitive
                            )
                        }
                    }
                    .disabled(query.isEmpty)
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Text("iPadOS selections are a single contiguous range. \"Select Lines Containing\" selects from the first matching line through the last. Use \"Keep Only Matching Lines\" or \"Remove Matching Lines\" when you need an exact filter.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Select Lines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func runOrReportError(_ work: () throws -> Void) {
        do {
            try work()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
