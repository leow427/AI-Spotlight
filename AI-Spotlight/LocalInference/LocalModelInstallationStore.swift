import Foundation

struct LocalModelInstallationStore: Sendable {
  struct FileOperations: Sendable {
    var copyItem: @Sendable (URL, URL) throws -> Void = {
      try FileManager.default.copyItem(at: $0, to: $1)
    }
    var moveItem: @Sendable (URL, URL) throws -> Void = {
      try FileManager.default.moveItem(at: $0, to: $1)
    }
    var writeMetadata: @Sendable (Data, URL) throws -> Void = {
      try $0.write(to: $1, options: .atomic)
    }
    var removeItem: @Sendable (URL) throws -> Void = {
      try FileManager.default.removeItem(at: $0)
    }
  }

  private struct Record: Codable {
    let id: String
    let displayName: String
    let fileName: String
    var catalogDescriptor: LocalModelDescriptor? = nil
    var visionConfiguration: LocalVisionConfiguration? = nil
  }

  private struct Library: Codable {
    var selectedModelID: String?
    var models: [Record]
  }

  private let modelsDirectory: URL
  private let recordURL: URL
  private let fileOperations: FileOperations

  // Downloads and imports can finish on different executors/store instances.
  // Serialize library transactions, including cleanup, within this process.
  private static let libraryLock = NSLock()

  var modelsDirectoryURL: URL { modelsDirectory }

  init(modelsDirectory: URL? = nil, fileOperations: FileOperations = FileOperations()) {
    let resolvedDirectory = modelsDirectory ?? FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "AI Spotlight/Models", directoryHint: .isDirectory)
    self.modelsDirectory = resolvedDirectory
    recordURL = resolvedDirectory.appending(path: "installed-model.json")
    self.fileOperations = fileOperations
  }

  func install(_ model: LocalModel) throws -> LocalModel {
    Self.libraryLock.lock()
    defer { Self.libraryLock.unlock() }

    try Task.checkCancellation()
    let sourceURL = model.fileURL.standardizedFileURL
    guard sourceURL.pathExtension.lowercased() == "gguf",
          FileManager.default.isReadableFile(atPath: sourceURL.path) else {
      throw LocalInferenceError.invalidModelFile
    }

    if model.supportsVision { try LocalVisionModelValidation.validate(model) }

    // Refuse to replace unreadable/corrupt metadata with an empty library.
    var library = try loadLibrary()
    let replacedRecords = library.models.filter { $0.id == model.id }
    try FileManager.default.createDirectory(
      at: modelsDirectory,
      withIntermediateDirectories: true
    )
    // Every import gets a fresh immutable file, including same-ID replacement.
    // The atomic metadata write is the commit point; existing bytes stay intact
    // until then. moveItem refuses to overwrite an occupied destination.
    let installationID = UUID().uuidString
    let fileName = "model-\(installationID).gguf"
    let destinationURL = modelsDirectory.appending(path: fileName)
    let temporaryURL = modelsDirectory.appending(
      path: ".installing-\(installationID).gguf"
    )
    defer { try? fileOperations.removeItem(temporaryURL) }

    var installedVision = model.visionConfiguration
    let projectorDestination = modelsDirectory.appending(path: "mmproj-\(installationID).gguf")
    let projectorTemporary = modelsDirectory.appending(path: ".installing-mmproj-\(installationID).gguf")
    var committed = false
    var movedModel = false
    var movedProjector = false
    defer {
      try? fileOperations.removeItem(projectorTemporary)
      if !committed {
        if movedModel { try? fileOperations.removeItem(destinationURL) }
        if movedProjector { try? fileOperations.removeItem(projectorDestination) }
      }
    }
    try fileOperations.copyItem(sourceURL, temporaryURL)
    try Task.checkCancellation()
    try fileOperations.moveItem(temporaryURL, destinationURL)
    movedModel = true
    if let vision = installedVision {
      try fileOperations.copyItem(vision.projectorURL, projectorTemporary)
      try Task.checkCancellation()
      try fileOperations.moveItem(projectorTemporary, projectorDestination)
      movedProjector = true
      installedVision = LocalVisionConfiguration(projectorURL: projectorDestination,
        serverExecutableURL: vision.serverExecutableURL, contextWindow: vision.contextWindow,
        managedRuntimeDirectory: vision.managedRuntimeDirectory, packageRevision: vision.packageRevision)
    }

    let record = Record(id: model.id, displayName: model.displayName, fileName: fileName,
                        catalogDescriptor: model.catalogDescriptor, visionConfiguration: installedVision)
    do {
      library.models.removeAll { $0.id == record.id }
      library.models.append(record)
      // Multimodal upgrades preserve the current selection. A new main package
      // becomes selected only at the same atomic commit as its complete files.
      if library.selectedModelID == nil || !model.supportsVision
        || (model.catalogDescriptor?.supportsVision == true && replacedRecords.isEmpty) {
        library.selectedModelID = record.id
      }
      try Task.checkCancellation()
      try saveLibrary(library)
      committed = true
    } catch {
      try? fileOperations.removeItem(destinationURL)
      throw error
    }

    // Legacy IDs may already share a file. Never remove another record's bytes.
    // Cleanup failure leaves an unused file, not a failed/rolled-back install.
    let retainedPaths = library.models.compactMap(modelFileURL(from:))
      .map { $0.resolvingSymlinksInPath().path }
    for previous in replacedRecords {
      guard let previousURL = modelFileURL(from: previous),
            !retainedPaths.contains(where: {
              $0.caseInsensitiveCompare(previousURL.resolvingSymlinksInPath().path) == .orderedSame
            }) else { continue }
      try? fileOperations.removeItem(previousURL)
      if let runtime = previous.visionConfiguration?.managedRuntimeDirectory,
         runtime.deletingLastPathComponent().standardizedFileURL == modelsDirectory.standardizedFileURL,
         runtime.lastPathComponent.hasPrefix("vision-runtime-"),
         !library.models.contains(where: { $0.visionConfiguration?.managedRuntimeDirectory == runtime }) {
        try? fileOperations.removeItem(runtime)
      }
      if let projector = previous.visionConfiguration?.projectorURL,
         projector.deletingLastPathComponent().standardizedFileURL == modelsDirectory.standardizedFileURL,
         !library.models.contains(where: { $0.visionConfiguration?.projectorURL == projector }) {
        try? fileOperations.removeItem(projector)
      }
    }
    return LocalModel(id: record.id, displayName: record.displayName, fileURL: destinationURL, catalogDescriptor: record.catalogDescriptor, visionConfiguration: installedVision)
  }

  func installedModel() -> LocalModel? {
    Self.libraryLock.lock()
    defer { Self.libraryLock.unlock() }
    guard let library = try? loadLibrary(),
          let selectedModelID = library.selectedModelID,
          let record = library.models.first(where: { $0.id == selectedModelID }) else { return nil }
    return localModel(from: record)
  }

  func installedModels() -> [LocalModel] {
    Self.libraryLock.lock()
    defer { Self.libraryLock.unlock() }
    return ((try? loadLibrary())?.models ?? []).compactMap(localModel(from:))
      .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
  }

  func selectModel(id: String) throws {
    Self.libraryLock.lock()
    defer { Self.libraryLock.unlock() }
    var library = try loadLibrary()
    guard let record = library.models.first(where: { $0.id == id }),
          localModel(from: record) != nil else {
      throw LocalInferenceError.unknownInstalledModel
    }
    library.selectedModelID = id
    try saveLibrary(library)
  }

  func deleteModel(id: String) throws {
    Self.libraryLock.lock()
    defer { Self.libraryLock.unlock() }

    var library = try loadLibrary()
    guard let record = library.models.first(where: { $0.id == id }) else {
      throw LocalInferenceError.unknownInstalledModel
    }
    let remainingRecords = library.models.filter { $0.id != id }
    var retainedPaths = Set(remainingRecords.compactMap(modelFileURL(from:)).map {
      $0.resolvingSymlinksInPath().path
    })
    for remaining in remainingRecords {
      if let projector = remaining.visionConfiguration?.projectorURL {
        retainedPaths.insert(projector.resolvingSymlinksInPath().path)
      }
      if let runtime = remaining.visionConfiguration?.managedRuntimeDirectory {
        retainedPaths.insert(runtime.resolvingSymlinksInPath().path)
      }
    }

    var resources: [URL] = []
    func appendManagedResource(_ url: URL?) {
      guard let url,
            !retainedPaths.contains(url.resolvingSymlinksInPath().path),
            !resources.contains(where: {
              $0.standardizedFileURL == url.standardizedFileURL
            }) else { return }
      resources.append(url)
    }
    appendManagedResource(modelFileURL(from: record))
    if let projector = record.visionConfiguration?.projectorURL,
       projector.deletingLastPathComponent().standardizedFileURL == modelsDirectory.standardizedFileURL {
      appendManagedResource(projector)
    }
    if let runtime = record.visionConfiguration?.managedRuntimeDirectory,
       runtime.deletingLastPathComponent().standardizedFileURL == modelsDirectory.standardizedFileURL,
       runtime.lastPathComponent.hasPrefix("vision-runtime-") {
      appendManagedResource(runtime)
    }

    // Move managed resources aside first so a metadata failure can restore the
    // complete installation. The atomic library write is the deletion commit.
    let deletionID = UUID().uuidString
    var stagedResources: [(source: URL, staged: URL)] = []
    do {
      for (index, source) in resources.enumerated()
      where FileManager.default.fileExists(atPath: source.path) {
        let staged = modelsDirectory.appending(path: ".deleting-\(deletionID)-\(index)")
        try fileOperations.moveItem(source, staged)
        stagedResources.append((source, staged))
      }
    } catch {
      for resource in stagedResources.reversed() {
        try? fileOperations.moveItem(resource.staged, resource.source)
      }
      throw error
    }

    library.models = remainingRecords
    if library.selectedModelID == id {
      library.selectedModelID = remainingRecords.compactMap(localModel(from:)).first?.id
    }
    do {
      try saveLibrary(library)
    } catch {
      for resource in stagedResources.reversed() {
        try? fileOperations.moveItem(resource.staged, resource.source)
      }
      throw error
    }

    // Cleanup after the commit is best effort. A failed cleanup can only leave
    // an unreferenced hidden tombstone, never a selectable partial model.
    for resource in stagedResources {
      try? fileOperations.removeItem(resource.staged)
    }
  }

  private func saveLibrary(_ library: Library) throws {
    try fileOperations.writeMetadata(JSONEncoder().encode(library), recordURL)
  }

  private func loadLibrary() throws -> Library {
    let data: Data
    do {
      data = try Data(contentsOf: recordURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return Library(selectedModelID: nil, models: [])
    }
    if let library = try? JSONDecoder().decode(Library.self, from: data) {
      return library
    }
    // Checkpoint 3 stored a single record. Keep that model when upgrading.
    let record = try JSONDecoder().decode(Record.self, from: data)
    return Library(selectedModelID: record.id, models: [record])
  }

  private func modelFileURL(from record: Record) -> URL? {
    let recordedFileURL = URL(fileURLWithPath: record.fileName)
    guard record.fileName == recordedFileURL.lastPathComponent,
          recordedFileURL.pathExtension.lowercased() == "gguf" else {
      return nil
    }

    return modelsDirectory.appending(path: record.fileName)
  }

  private func localModel(from record: Record) -> LocalModel? {
    guard let fileURL = modelFileURL(from: record),
          FileManager.default.isReadableFile(atPath: fileURL.path) else {
      return nil
    }
    if let vision = record.visionConfiguration {
      guard vision.projectorURL.deletingLastPathComponent().standardizedFileURL == modelsDirectory.standardizedFileURL,
            FileManager.default.isReadableFile(atPath: vision.projectorURL.path) else { return nil }
    }
    return LocalModel(
      id: record.id,
      displayName: record.displayName,
      fileURL: fileURL,
      catalogDescriptor: record.catalogDescriptor,
      visionConfiguration: record.visionConfiguration
    )
  }
}
