import Foundation

struct LocalModelInstallationStore: Sendable {
  private struct Record: Codable {
    let id: String
    let displayName: String
    let fileName: String
  }

  private let modelsDirectory: URL
  private let recordURL: URL

  init(modelsDirectory: URL? = nil) {
    let resolvedDirectory = modelsDirectory ?? FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "AI Spotlight/Models", directoryHint: .isDirectory)
    self.modelsDirectory = resolvedDirectory
    recordURL = resolvedDirectory.appending(path: "installed-model.json")
  }

  func install(_ model: LocalModel) throws -> LocalModel {
    let sourceURL = model.fileURL.standardizedFileURL
    guard sourceURL.pathExtension.lowercased() == "gguf",
          FileManager.default.isReadableFile(atPath: sourceURL.path) else {
      throw LocalInferenceError.invalidModelFile
    }

    try FileManager.default.createDirectory(
      at: modelsDirectory,
      withIntermediateDirectories: true
    )
    let fileName = "\(sanitized(model.id)).gguf"
    let destinationURL = modelsDirectory.appending(path: fileName)
    let temporaryURL = modelsDirectory.appending(
      path: ".installing-\(UUID().uuidString).gguf"
    )

    do {
      try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
      if FileManager.default.fileExists(atPath: destinationURL.path) {
        _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
      } else {
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
      }

      let record = Record(
        id: model.id,
        displayName: model.displayName,
        fileName: fileName
      )
      let data = try JSONEncoder().encode(record)
      try data.write(to: recordURL, options: .atomic)
      return LocalModel(
        id: record.id,
        displayName: record.displayName,
        fileURL: destinationURL
      )
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
  }

  func installedModel() -> LocalModel? {
    guard let data = try? Data(contentsOf: recordURL),
          let record = try? JSONDecoder().decode(Record.self, from: data) else {
      return nil
    }

    let recordedFileURL = URL(fileURLWithPath: record.fileName)
    guard record.fileName == recordedFileURL.lastPathComponent,
          recordedFileURL.pathExtension.lowercased() == "gguf" else {
      return nil
    }

    let fileURL = modelsDirectory.appending(path: record.fileName)
    guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
      return nil
    }
    return LocalModel(
      id: record.id,
      displayName: record.displayName,
      fileURL: fileURL
    )
  }

  private func sanitized(_ modelID: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let result = String(modelID.unicodeScalars.map { scalar in
      allowed.contains(scalar) ? String(scalar) : "-"
    }.joined().prefix(80))
    return result.isEmpty ? "local-model" : result
  }
}
