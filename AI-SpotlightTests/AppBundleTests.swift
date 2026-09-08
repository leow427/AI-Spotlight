import Foundation
import XCTest

final class AppBundleTests: XCTestCase {
  func testEmbeddedLocalInferenceFrameworkResolvesWithoutXcodeSearchPaths() throws {
    let app = Bundle.main.bundleURL
    let executable = try XCTUnwrap(Bundle.main.executableURL)
    let executableDirectory = executable.deletingLastPathComponent()
    let debugLibrary = executableDirectory.appendingPathComponent(executable.lastPathComponent + ".debug.dylib")
    let images = [executable, debugLibrary].filter { FileManager.default.fileExists(atPath: $0.path) }
    var searchDirectories: [URL] = []
    var dependencies = Set<String>()

    for image in images {
      let commands = try inspect(["-l", image.path]).components(separatedBy: "\n")
      var isRunpath = false
      for line in commands {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("cmd ") { isRunpath = text == "cmd LC_RPATH" }
        if isRunpath, text.hasPrefix("path "), let end = text.range(of: " (offset ") {
          let path = String(text[text.index(text.startIndex, offsetBy: 5)..<end.lowerBound])
            .replacingOccurrences(of: "@executable_path", with: executableDirectory.path)
            .replacingOccurrences(of: "@loader_path", with: image.deletingLastPathComponent().path)
          searchDirectories.append(URL(fileURLWithPath: path).standardizedFileURL)
        }
      }
      for line in try inspect(["-L", image.path]).components(separatedBy: "\n") {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("@rpath/llama.framework/"), let end = text.range(of: " (compatibility version") {
          dependencies.insert(String(text[..<end.lowerBound].dropFirst("@rpath/".count)))
        }
      }
    }

    XCTAssertFalse(dependencies.isEmpty, "The app must link its local inference runtime.")
    for dependency in dependencies {
      let resolvesInsideApp = searchDirectories.contains { directory in
        let candidate = directory.appendingPathComponent(dependency).resolvingSymlinksInPath()
        return candidate.path.hasPrefix(app.resolvingSymlinksInPath().path + "/")
          && FileManager.default.isReadableFile(atPath: candidate.path)
      }
      XCTAssertTrue(resolvesInsideApp,
        "The packaged app cannot resolve \(dependency) using its own runpaths. XCTest's DYLD_FRAMEWORK_PATH must not hide a launch failure.")
    }
  }

  private func inspect(_ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
    process.arguments = arguments
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    return String(decoding: data, as: UTF8.self)
  }
}
