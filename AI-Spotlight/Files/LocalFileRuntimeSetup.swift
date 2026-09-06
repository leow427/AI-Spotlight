import Foundation
import SwiftUI

enum LocalFileRuntimeSetup {
  static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "AI Spotlight/File Tools", directoryHint: .isDirectory)
  }
  static var executable: URL { directory.appending(path: LocalVisionRuntime.directoryName + "/llama-server") }

  static func install(progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws {
    if FileManager.default.isExecutableFile(atPath: executable.path) { return }
    let runtime = LocalVisionRuntime.bundled
    try runtime.validate()
    let staging = directory.deletingLastPathComponent().appending(path: ".file-tools-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    let archive = staging.appendingPathComponent("runtime.tar.gz")
    try await runtime.archive.download(to: archive, session: .shared, progress: progress)
    // Existing verified download/extraction path; this is app setup, never an agent command.
    _ = try await runtime.install(archive: archive, staging: staging, destination: directory)
  }
}

struct LocalFileToolsSetupView: View {
  let model: LocalModel?
  @State private var installing = false
  @State private var progress: Double = 0
  @State private var error: String?
  @State private var ready = false
  @State private var task: Task<Void, Never>?
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Local File Tools").font(.subheadline.weight(.medium))
      if ready || model.map({ LocalFileRuntime.executable(for: $0) != nil }) == true {
        Text("Ready · Notes and text files can be edited locally. Protected edits offer Codex with your permission, or use a local fallback when Codex is unavailable. Review and Undo remain available.")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Text("Install the small file-tools runtime once to analyze files with imported local models. This download sends no attached files.")
          .font(.caption).foregroundStyle(.secondary)
        if installing {
          ProgressView(value: progress)
          Button("Cancel") { task?.cancel() }
        } else {
          Button("Install Local File Tools (11 MB)") {
            installing = true
            error = nil
            task = Task { @MainActor in
              defer { installing = false; task = nil }
              do {
                try await LocalFileRuntimeSetup.install { update in
                  await MainActor.run {
                    progress = Double(update.receivedByteCount) / Double(max(1, update.expectedByteCount))
                  }
                }
                ready = true
              } catch is CancellationError { }
              catch { self.error = error.localizedDescription }
            }
          }
        }
      }
      if let error { Text(error).font(.caption).foregroundStyle(.orange) }
    }
    .onDisappear { task?.cancel() }
  }
}
