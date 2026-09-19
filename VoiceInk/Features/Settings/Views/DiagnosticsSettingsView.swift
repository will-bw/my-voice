import SwiftData
import SwiftUI

struct DiagnosticsSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var isExportingLogs = false
    @State private var exportedLogURL: URL?
    @State private var showLogExportError = false
    @State private var logExportError: String = ""
    @State private var showExportPreview = false

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let url = exportedLogURL {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }

                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(AppTheme.Status.positive)
                }

                Button("Review & Export") { showExportPreview = true }
                .disabled(isExportingLogs)
            }
        } label: {
            HStack(spacing: 4) {
                if isExportingLogs {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("Redacted Diagnostics")
            }
        }
        .alert("Export Failed", isPresented: $showLogExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(logExportError)
        }
        .alert("Diagnostic Package Contents", isPresented: $showExportPreview) {
            Button("Cancel", role: .cancel) {}
            Button("Export…") { exportDiagnosticLogs() }
        } message: {
            Text(RedactedDiagnosticExporter.previewText)
        }
    }

    private func exportDiagnosticLogs() {
        isExportingLogs = true
        exportedLogURL = nil

        Task {
            do {
                let url = try await MainActor.run {
                    try RedactedDiagnosticExporter.export(from: modelContext)
                }
                await MainActor.run {
                    exportedLogURL = url
                    isExportingLogs = false
                }
            } catch {
                await MainActor.run {
                    logExportError = error.localizedDescription
                    showLogExportError = true
                    isExportingLogs = false
                }
            }
        }
    }
}
