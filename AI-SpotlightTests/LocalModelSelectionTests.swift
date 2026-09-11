import AppKit
import CryptoKit
import Foundation
import SwiftUI
import XCTest
@testable import Enigma

final class LocalModelSelectionTests: XCTestCase {
  private let gib = LocalHardwareProfile.gib
  private var catalog: LocalModelManifest { .bundled }

  func testRequestedHardwareTiersContainExactPackagesAndQuantizations() throws {
    let expected: [Int: [[String]]] = [
      16: [["smolvlm2-2.2b-q8_0"], ["qwen3.5-4b-q4_k_m", "gemma-4-e4b-q4_k_m"],
           ["ministral-3-8b-q4_k_m", "minicpm-o-4.5-q4_k_m"]],
      24: [["qwen3.5-4b-q5_k_m"], ["qwen3.5-9b-q5_k_m", "minicpm-o-4.5-q5_k_m"],
           ["gemma-4-12b-q5_k_m", "ministral-3-14b-q5_k_m"]],
      32: [["qwen3.5-4b-q8_0"], ["minicpm-o-4.5-q5_k_m", "gemma-4-12b-q5_k_m"],
           ["ministral-3-14b-q8_0", "gemma-4-26b-a4b-q4_k_m"]]
    ]
    for memory in [16, 18, 24, 32] {
      let recommendations = LocalModelSelector.select(manifest: catalog, hardware: hardware(memory: memory))
      XCTAssertEqual(recommendations.tierGroups.map(\.weight), LocalModelWeight.allCases)
      XCTAssertEqual(recommendations.tierGroups.map { $0.models.map(\.id) }, expected[memory == 18 ? 16 : memory])
      XCTAssertEqual(recommendations.tierGroups.flatMap { $0.models }.count, 5)
      let tierIDs = Set(recommendations.tierGroups.flatMap { $0.models.map(\.id) })
      XCTAssertEqual(tierIDs.union(recommendations.otherTierAssessments.map(\.id)), Set(catalog.models.map(\.id)))
      if let recommended = recommendations.recommended {
        XCTAssertTrue(tierIDs.contains(recommended.id))
        XCTAssertTrue(recommended.isResponsive)
      }
    }
  }

  func testNewCatalogueDoesNotMisrepresentUnavailableRuntimeOrAudio() throws {
    let mini = catalog.models.filter { $0.inferenceProfile == .miniCPMO45 }
    XCTAssertEqual(mini.count, 2)
    for model in mini {
      try model.validate()
      let assessment = LocalModelSelector.assess(model, hardware: hardware(memory: 128))
      XCTAssertEqual(assessment.fit, .unsupported)
      XCTAssertFalse(assessment.canInstall)
      XCTAssertTrue(assessment.reason.contains("dedicated runtime"))
      XCTAssertEqual(model.modelSupportsAudio, true)
    }
    for model in catalog.models {
      XCTAssertNotNil(model.advertisedMemoryRange)
      XCTAssertTrue(model.downloadURL.lastPathComponent.contains(model.quantization))
      if model.modelSupportsAudio == true {
        XCTAssertTrue(model.performanceClass.contains("Text and images in Enigma"))
      }
    }
    XCTAssertFalse(catalog.models.contains { $0.id.contains("qwen3-vl") || $0.id.contains("minicpm-v") })
  }

  func testEnigmaProductKeepsExistingUserDataIdentity() {
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Enigma")
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "Enigma")
    XCTAssertEqual(Bundle.main.bundleIdentifier, "com.leow427.AISpotlight")
  }

  func testCatalogPinsEveryQuantizationAndMatchesEmbeddedBuild() throws {
    try catalog.validate()
    XCTAssertEqual(catalog.models.count, 13)
    XCTAssertEqual(Set(catalog.models.map(\.quantization)), ["Q4_K_M", "Q5_K_M", "Q8_0"])
    XCTAssertEqual(Set(catalog.models.map(\.maker)), ["Alibaba / Qwen", "Google", "Mistral AI", "OpenBMB", "Hugging Face"])
    XCTAssertEqual(Set(catalog.models.compactMap(\.resolvedProfile)), Set([.smolVLM2, .qwen35_4B, .qwen35_9B, .gemma4E4B, .gemma4_12B, .gemma4A4B, .ministral8B, .ministral14B, .miniCPMO45]))
    for model in catalog.models {
      XCTAssertEqual(LocalModelCompatibility.supports(model), model.inferenceProfile != .miniCPMO45)
      XCTAssertTrue(model.supportsVision)
      XCTAssertNotNil(model.modelSummary)
      XCTAssertLessThanOrEqual(model.summary.count, 300)
      XCTAssertTrue(model.summary.hasSuffix("."))
      XCTAssertNotNil(model.projector)
      XCTAssertEqual(model.runtimeBuild, LocalVisionRuntime.build)
      XCTAssertGreaterThanOrEqual(model.recommendedContextSize, 4_096)
      XCTAssertEqual(model.downloadURL.pathComponents[4], model.revision)
    }
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Packages/LlamaBridge/Package.swift")
    XCTAssertTrue(try String(contentsOf: source, encoding: .utf8).contains("releases/download/b\(LocalModelCompatibility.llamaBuild)/"))
  }

  func testGemmaTwelveBUsesPinnedOfficialQuantizedPackage() throws {
    let model = try XCTUnwrap(LegacyModelFixtures.models.first { $0.id == "gemma-4-12b-it-qat-q4_0-gguf" })
    XCTAssertEqual(model.displayName, "Google Gemma 4 12B")
    XCTAssertEqual(model.revision, "29d097773436b69ff9feafd636ab4cf873786537")
    XCTAssertEqual(model.expectedByteCount, 6_975_879_296)
    XCTAssertEqual(model.checksumSHA256, "93567e57a8fe10b23569b9d9ec38cd005deedf71e29477c421a4b83f418a538b")
    XCTAssertEqual(model.projector?.expectedByteCount, 175_115_616)
    XCTAssertEqual(model.projector?.checksumSHA256, "cb018338a7538a9814d994bfe54644c71eb7ed54e31eae2f721e45fd3c260da7")
    XCTAssertEqual(model.inferenceProfile, .gemma4_12B)
    XCTAssertEqual(model.quantization, "Q4_0")
    XCTAssertEqual(LocalModelCompatibility.supports(model), model.inferenceProfile != .miniCPMO45)
  }

  func testCompatibleModelsCanBeInstalledAndLoadedWithMemoryWarnings() throws {
    let gemma = try XCTUnwrap(LegacyModelFixtures.models.first { $0.id == "gemma-4-12b-it-qat-q4_0-gguf" })
    let insufficientMemory = LocalModelSelector.assess(gemma, hardware: hardware(memory: 24))
    XCTAssertEqual(insufficientMemory.fit, .memory)
    XCTAssertTrue(insufficientMemory.permitsMemoryOverride)
    XCTAssertTrue(insufficientMemory.canInstall)

    let other = try XCTUnwrap(catalog.models.first { $0.id != gemma.id })
    let blocked = LocalModelSelector.assess(other, hardware: hardware(memory: 4))
    XCTAssertEqual(blocked.fit, .memory)
    XCTAssertTrue(blocked.permitsMemoryOverride)
    XCTAssertTrue(blocked.canInstall)
    XCTAssertFalse(blocked.fit.canRun, "Memory warnings must still exclude this model from automatic recommendations")
  }

  func testTopTenAreDeterministicHardwareRankedAndNeverPaddedWithUnsafeModels() throws {
    var mac = hardware(memory: 128)
    mac.performanceCPUCount = 16
    let choices = LocalModelSelector.select(manifest: catalog, hardware: mac)
    XCTAssertEqual(choices.rankedChoices.count, 10)
    XCTAssertTrue(choices.tierGroups.flatMap { $0.models }.contains { $0.id == choices.recommended?.id })
    XCTAssertEqual(Set(choices.rankedChoices.map(\.id)).count, 10)
    XCTAssertTrue(choices.rankedChoices.allSatisfy { $0.fit.canRun })
    XCTAssertGreaterThanOrEqual(Set(choices.rankedChoices.map(\.model.maker)).count, 3)
    let reversed = LocalModelSelector.select(manifest: LocalModelManifest(version: catalog.version,
      models: catalog.models.reversed()), hardware: mac)
    XCTAssertEqual(choices.rankedChoices.map(\.id), reversed.rankedChoices.map(\.id))
    XCTAssertEqual(Set(choices.rankedChoices.map(\.id)).union(choices.otherAssessments.map(\.id)), Set(catalog.models.map(\.id)))
    for (higher, lower) in zip(choices.rankedChoices, choices.rankedChoices.dropFirst()) {
      XCTAssertTrue(LocalModelSelector.hardwareOrder(higher, lower))
    }
    let small = LocalModelSelector.select(manifest: catalog, hardware: hardware(memory: 8))
    XCTAssertTrue(small.rankedChoices.isEmpty)
    XCTAssertNil(small.recommended)
    XCTAssertEqual(small.otherAssessments.count, catalog.models.count)
    let ordinary = LocalModelSelector.select(manifest: catalog, hardware: hardware(memory: 24))
    XCTAssertLessThan(ordinary.rankedChoices.count, 10)
    XCTAssertGreaterThanOrEqual(Set(ordinary.rankedChoices.map(\.model.maker)).count, 3)
    XCTAssertTrue(ordinary.rankedChoices.allSatisfy { $0.model.minimumMemory <= 24 * gib })
    mac.availableDiskBytes = 0
    XCTAssertTrue(LocalModelSelector.select(manifest: catalog, hardware: mac).rankedChoices.isEmpty)
  }

  func testEveryFamilyHasAReviewedMemoryFloorAndRejectsMismatchedProfiles() throws {
    for model in catalog.models {
      let profile = try XCTUnwrap(model.resolvedProfile)
      let projector = try XCTUnwrap(model.projector)
      let required = profile.memory(weights: model.expectedByteCount, projector: projector.expectedByteCount, context: 8192)
      XCTAssertGreaterThanOrEqual(model.estimatedRuntimeMemory, required)
      XCTAssertThrowsError(try modifying(model, ["estimatedRuntimeMemory": required - 1]).validate())
      let incorrect = try modifying(model, ["chatTemplate": "another-family"])
      XCTAssertEqual(LocalModelSelector.assess(incorrect, hardware: hardware(memory: 128)).fit, .unsupported)
      let record = benchmark(model: model, hardware: hardware(memory: 128), speed: 2)
      XCTAssertTrue(record.isApplicable(to: hardware(memory: 128)))
      let measured = LocalModelSelector.select(manifest: catalog, hardware: hardware(memory: 128), measurements: [record])
      XCTAssertTrue(try XCTUnwrap(measured.assessments.first { $0.id == model.id }).isMeasured)
      XCTAssertNotEqual(measured.recommended?.id, model.id)
    }
    XCTAssertEqual(LocalMultimodalProfile.ministral14B.cacheBytesPerToken, 163_840)
    XCTAssertEqual(LocalMultimodalProfile.gemma4E4B.cacheBytesPerToken, 100_352)
    let moe = try XCTUnwrap(catalog.models.first { $0.inferenceProfile == .gemma4A4B })
    XCTAssertGreaterThan(moe.expectedByteCount, 14_000_000_000)
    XCTAssertGreaterThan(moe.estimatedRuntimeMemory, 20 * gib)
  }

  func testOldInstalledDescriptorDecodesWithoutDescriptionsOrProfilesAndKeepsPackageIdentity() throws {
    let model = LegacyModelFixtures.models[0]
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
    for key in ["publisher", "modelSummary", "inferenceProfile"] { json.removeValue(forKey: key) }
    let restored = try JSONDecoder().decode(LocalModelDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
    try restored.validate()
    XCTAssertEqual(restored.packageRevision, model.packageRevision)
    XCTAssertTrue(LocalModelCompatibility.supports(restored))
    XCTAssertFalse(restored.summary.isEmpty)
    XCTAssertEqual(restored.maker, "Alibaba / Qwen")
  }

  func testBudgetReservesOSMemoryAndHonorsMetalWorkingSet() {
    var mac = hardware(memory: 8)
    XCTAssertEqual(mac.inferenceMemoryBudget, 4 * gib)
    mac.physicalMemory = 4 * gib
    XCTAssertEqual(mac.inferenceMemoryBudget, 0)
    mac.physicalMemory = 64 * gib
    mac.metalRecommendedWorkingSet = 10 * gib
    XCTAssertEqual(mac.inferenceMemoryBudget, 8 * gib)
    mac.metalRecommendedWorkingSet = nil
    XCTAssertLessThanOrEqual(mac.inferenceMemoryBudget, mac.physicalMemory - mac.osReserve)
  }

  func testSafetyGatesCannotBeOutweighedByQualityAcrossMemoryAndDiskSizes() {
    for memory in [4, 8, 12, 16, 24, 32, 48, 64, 128] {
      for disk in [0, 4, 20, 100] {
        var mac = hardware(memory: memory)
        mac.availableDiskBytes = Int64(disk) * gib
        let results = LocalModelSelector.select(manifest: catalog, hardware: mac)
        for candidate in [results.recommended, results.faster, results.smarter].compactMap({ $0 }) {
          XCTAssertTrue(candidate.fit.canRun)
          XCTAssertLessThanOrEqual(candidate.model.estimatedRuntimeMemory, mac.inferenceMemoryBudget)
          XCTAssertGreaterThanOrEqual(mac.availableDiskBytes, candidate.model.downloadByteCount * 2 + 2 * gib)
          XCTAssertGreaterThanOrEqual(candidate.model.recommendedContextSize, 4_096)
        }
        if let recommended = results.recommended {
          XCTAssertTrue(recommended.isResponsive)
          XCTAssertEqual(recommended.model.qualityScore,
                         results.tierGroups.flatMap { $0.models }.filter(\.isResponsive).map(\.model.qualityScore).max())
        }
      }
    }
  }

  func testChipNamesDoNotControlSelectionAndCPUResourcesDo() throws {
    var mac = hardware(memory: 64)
    mac.performanceCPUCount = 12
    let first = LocalModelSelector.select(manifest: catalog, hardware: mac)
    mac.chip = "A future chip with an unknown name"
    XCTAssertEqual(first.recommended?.id, LocalModelSelector.select(manifest: catalog, hardware: mac).recommended?.id)
    mac.performanceCPUCount = 2
    mac.cpuCount = 2
    XCTAssertNotEqual(first.recommended?.id, LocalModelSelector.select(manifest: catalog, hardware: mac).recommended?.id)
    let recommended = try XCTUnwrap(first.recommended)
    XCTAssertLessThan(try XCTUnwrap(first.faster).model.estimatedRuntimeMemory, recommended.model.estimatedRuntimeMemory)
    XCTAssertGreaterThan(try XCTUnwrap(first.smarter).model.qualityScore, recommended.model.qualityScore)
    XCTAssertEqual(Set([first.recommended?.id, first.faster?.id, first.smarter?.id].compactMap { $0 }).count, 3)
  }

  func testDiskCheckIncludesInstallerCopyButInstalledModelsRemainUsable() {
    var mac = hardware()
    let model = catalog.models[0]
    mac.availableDiskBytes = model.downloadByteCount * 2 + 2 * gib - 1
    XCTAssertEqual(LocalModelSelector.assess(model, hardware: mac).fit, .disk)
    XCTAssertTrue(LocalModelSelector.assess(model, hardware: mac, installed: true).fit.canRun)
    mac.availableDiskBytes += 1
    XCTAssertTrue(LocalModelSelector.assess(model, hardware: mac).fit.canRun)
  }

  func testCompatibilityRejectsUnsupportedArchitectureTemplateQuantizationContextAndBuild() throws {
    for fields: [String: Any] in [
      ["architecture": "qwen3"], ["chatTemplate": "unknown"], ["quantization": "IQ1_S"],
      ["recommendedContextSize": 2_048], ["minimumLlamaBuild": 99_999],
    ] {
      let model = try modifying(catalog.models[0], fields)
      XCTAssertEqual(LocalModelSelector.assess(model, hardware: hardware()).fit, .unsupported)
    }
    var mac = hardware()
    mac.metalMaximumBufferLength = 512 * 1_024 * 1_024
    XCTAssertEqual(LocalModelSelector.assess(catalog.models[0], hardware: mac).fit, .unsupported)
    mac.hasUnifiedMemory = false
    XCTAssertEqual(LocalModelSelector.assess(catalog.models[0], hardware: mac).fit, .unsupported)
    mac.hasMetal = false
    mac.isAppleSilicon = false
    XCTAssertTrue(LocalModelSelector.assess(catalog.models[0], hardware: mac).fit.canRun)
    mac.cpuCount = 1
    mac.performanceCPUCount = 1
    XCTAssertNil(LocalModelSelector.select(manifest: catalog, hardware: mac).recommended)
  }

  func testManifestRejectsMutableURLsBadHashesDuplicateIDsAndInvalidEstimates() throws {
    for fields: [String: Any] in [
      ["revision": "main"], ["downloadURL": "https://example.com/model.gguf"],
      ["checksumSHA256": "not-a-checksum"], ["expectedByteCount": -1],
      ["expectedByteCount": Int64.max], ["recommendedContextSize": Int.max], ["qualityScore": 101],
      ["estimatedRuntimeMemory": 1], ["minimumMemory": 1], ["parameterBillions": 0],
    ] {
      XCTAssertThrowsError(try modifying(catalog.models[0], fields).validate())
    }
    XCTAssertThrowsError(try LocalModelManifest(version: 1, models: [catalog.models[0], catalog.models[0]]).validate())
  }

  func testActualSlowdownChangesRecommendationAndSuggestsSmallerModel() throws {
    let mac = hardware(memory: 32)
    let original = LocalModelSelector.select(manifest: catalog, hardware: mac)
    let recommended = try XCTUnwrap(original.recommended)
    let record = benchmark(model: recommended.model, hardware: mac, speed: 4)
    XCTAssertTrue(record.underperformed)
    let measured = LocalModelSelector.select(manifest: catalog, hardware: mac, measurements: [record])
    XCTAssertNotEqual(measured.recommended?.id, recommended.id)
    let current = try XCTUnwrap(measured.assessments.first { $0.id == recommended.id })
    XCTAssertTrue(current.isMeasured)
    XCTAssertEqual(current.tokensPerSecond, 4)
    XCTAssertEqual(current.fit, .slow)
    XCTAssertNotNil(measured.fasterAlternative(to: recommended.id))
    let alternative = try XCTUnwrap(measured.fasterAlternative(to: recommended.id))
    XCTAssertFalse(alternative.isMeasured)
  }

  func testMeasurementsAreScopedToMacRuntimeContextChecksumAgeAndPowerMode() throws {
    let mac = hardware()
    let model = catalog.models[0]
    let record = benchmark(model: model, hardware: mac, speed: 4)
    XCTAssertTrue(record.isApplicable(to: mac))
    var anotherMac = mac
    anotherMac.physicalMemory *= 2
    XCTAssertFalse(record.isApplicable(to: anotherMac))
    anotherMac = mac
    anotherMac.lowPowerMode = true
    XCTAssertFalse(record.isApplicable(to: anotherMac))
    XCTAssertFalse(record.isApplicable(to: mac, now: .now.addingTimeInterval(91 * 86_400)))
    let changedContext = try modifying(model, ["recommendedContextSize": 4_096])
    XCTAssertFalse(LocalModelSelector.assess(changedContext, hardware: mac, measurements: [record]).isMeasured)
    let changedChecksum = try modifying(model, ["checksumSHA256": String(repeating: "a", count: 64)])
    XCTAssertFalse(LocalModelSelector.assess(changedChecksum, hardware: mac, measurements: [record]).isMeasured)
  }

  func testFastRealMeasurementsCanPromoteASmarterModelWithoutOverridingMemorySafety() throws {
    var mac = hardware(memory: 64)
    mac.performanceCPUCount = 12
    let initial = LocalModelSelector.select(manifest: catalog, hardware: mac)
    let recommended = try XCTUnwrap(initial.recommended)
    let measurement = benchmark(model: recommended.model, hardware: mac, speed: 100, promptSpeed: 4_000)
    let learned = LocalModelSelector.select(manifest: catalog, hardware: mac, measurements: [measurement])
    let smarter = try XCTUnwrap(learned.recommended)
    XCTAssertGreaterThan(smarter.model.qualityScore, recommended.model.qualityScore)
    XCTAssertLessThanOrEqual(smarter.model.estimatedRuntimeMemory, mac.inferenceMemoryBudget)
    XCTAssertTrue(smarter.isResponsive)
  }

  func testMeasuredMemoryCanDisqualifyModelThatEstimatedToFit() {
    let mac = hardware()
    let model = catalog.models[0]
    let record = benchmark(model: model, hardware: mac, memory: mac.inferenceMemoryBudget + 1)
    XCTAssertEqual(LocalModelSelector.assess(model, hardware: mac, measurements: [record]).fit, .memory)
  }

  func testSignedCatalogAcceptsTrustedUpdateAndRejectsTamperingWrongKeyAndRollback() throws {
    let key = Curve25519.Signing.PrivateKey()
    let trust = LocalCatalogTrust(url: URL(string: "https://example.com/catalog.json")!, publicKey: key.publicKey.rawRepresentation)
    let updated = LocalModelManifest(version: catalog.version + 1, models: catalog.models)
    let signed = try signedData(updated, key: key)
    XCTAssertEqual(try trust.verify(signed, minimumVersion: 1), updated)
    XCTAssertThrowsError(try trust.verify(signed, minimumVersion: updated.version + 1))
    XCTAssertThrowsError(try trust.verify(signedData(updated, key: .init()), minimumVersion: 1))
    let envelope = try JSONDecoder().decode(SignedLocalModelCatalog.self, from: signed)
    let tampered = SignedLocalModelCatalog(payload: Data("tampered".utf8), signature: envelope.signature)
    XCTAssertThrowsError(try trust.verify(JSONEncoder().encode(tampered), minimumVersion: 1))
    XCTAssertThrowsError(try trust.verify(Data(repeating: 0, count: 1_048_577), minimumVersion: 1))
    let unsupported = LocalModelManifest(version: 3, models: [try modifying(catalog.models[0], ["architecture": "future"] )])
    let validButUnsupported = try trust.verify(signedData(unsupported, key: key), minimumVersion: 1)
    XCTAssertNil(LocalModelSelector.select(manifest: validButUnsupported, hardware: hardware()).recommended)
  }

  func testMonthlyCadenceAndCachedCatalogFallback() async throws {
    let root = try temporaryDirectory()
    let key = Curve25519.Signing.PrivateKey()
    let trust = LocalCatalogTrust(url: URL(string: "https://example.invalid/catalog.json")!, publicKey: key.publicKey.rawRepresentation)
    let updated = LocalModelManifest(version: catalog.version + 1, models: catalog.models)
    let now = Date()
    try signedData(updated, key: key).write(to: root.appending(path: "signed-model-catalog.json"))
    try JSONEncoder().encode(now).write(to: root.appending(path: "catalog-last-check.json"))
    let updater = LocalCatalogUpdater(directory: root, trust: trust)
    let cached = await updater.catalog(now: now)
    XCTAssertEqual(cached, updated)
    try Data("corrupt".utf8).write(to: root.appending(path: "signed-model-catalog.json"))
    let fallback = await updater.catalog(now: now)
    XCTAssertEqual(fallback, catalog)
    XCTAssertTrue(LocalCatalogUpdater.isDue(lastCheck: nil, now: now))
    XCTAssertFalse(LocalCatalogUpdater.isDue(lastCheck: now, now: now.addingTimeInterval(29 * 86_400)))
    XCTAssertTrue(LocalCatalogUpdater.isDue(lastCheck: now, now: now.addingTimeInterval(30 * 86_400)))
  }

  @MainActor
  func testFirstRunOnlyPresentsWithNoModelsAndDeveloperReplayDoesNotResetLibrary() async throws {
    let root = try temporaryDirectory()
    let suite = "ModelAdvisorTests-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let profile = hardware()
    func makeAdvisor() -> LocalModelAdvisor {
      LocalModelAdvisor(directory: root, modelsDirectory: root, defaults: defaults, trust: nil, detect: { _ in profile })
    }
    let advisor = makeAdvisor()
    await advisor.start(installedModels: [])
    XCTAssertTrue(advisor.isOnboardingPresented)
    XCTAssertNotNil(advisor.hardware)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "hardware.json").path))
    advisor.dismissOnboarding()
    let restored = makeAdvisor()
    await restored.start(installedModels: [])
    XCTAssertFalse(restored.isOnboardingPresented)
    await restored.replayOnboarding()
    XCTAssertTrue(restored.isOnboardingPresented)
    defaults.removeObject(forKey: "localModelOnboardingDismissed")
    let installed = LocalModel(id: "existing", displayName: "Existing", fileURL: root.appending(path: "existing.gguf"))
    let upgrading = makeAdvisor()
    await upgrading.start(installedModels: [installed])
    XCTAssertFalse(upgrading.isOnboardingPresented)
    let selection = upgrading.recommendations(installedModels: [installed])
    XCTAssertNotNil(selection.recommended)
  }

  @MainActor
  func testBenchmarksPersistLocallyAndDoNotChangeSelectedModel() async throws {
    let root = try temporaryDirectory()
    let profile = hardware()
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in profile })
    await advisor.detectHardware()
    let descriptor = catalog.models[0]
    let source = root.appending(path: "test.gguf")
    try Data("fixture".utf8).write(to: source)
    let store = LocalModelInstallationStore(modelsDirectory: root.appending(path: "models"))
    let installed = try store.install(LocalModel(id: descriptor.id, displayName: descriptor.displayName,
      fileURL: source, catalogDescriptor: descriptor))
    XCTAssertEqual(store.installedModel()?.catalogDescriptor, descriptor)
    advisor.record(benchmark(model: descriptor, hardware: profile).metrics, model: installed, prediction: nil)
    let restored = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in profile })
    await restored.detectHardware()
    XCTAssertEqual(restored.measurements, advisor.measurements)
    XCTAssertNotNil(restored.latestBenchmark(for: installed))
    XCTAssertEqual(store.installedModel(), installed)
  }

  @MainActor
  func testOnboardingAndModelManagerRenderWithRealSelectionResults() async throws {
    let root = try temporaryDirectory()
    let profile = hardware(memory: 32)
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in profile })
    await advisor.detectHardware()
    let chat = LocalChatViewModel(engine: SelectionTestEngine(), sessionStore: ChatSessionStore(applicationSupportDirectory: root))
    try render(LocalModelOnboardingView(advisor: advisor, chat: chat), size: NSSize(width: 560, height: 650), name: "local-model-onboarding")
    try render(Form { LocalModelManagerSection(advisor: advisor, chat: chat) }.formStyle(.grouped),
               size: NSSize(width: 560, height: 740), name: "local-model-manager")
  }

  @MainActor
  func testInstallationBenchmarksBeforeAllowingChatAndKeepsSelectionOnSlowResult() async throws {
    let root = try temporaryDirectory()
    let mac = hardware(memory: 32)
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in mac })
    await advisor.detectHardware()
    let candidate = try XCTUnwrap(advisor.recommendations(installedModels: []).recommended)
    let started = expectation(description: "Benchmark started after installation")
    let engine = SelectionWorkflowEngine(started: { started.fulfill() })
    let chat = LocalChatViewModel(engine: engine, modelAdvisor: advisor,
      sessionStore: ChatSessionStore(applicationSupportDirectory: root))
    let finished = expectation(description: "Installation and benchmark finished")
    let subscription = chat.$state.dropFirst().sink { if $0 == .idle { finished.fulfill() } }
    defer { subscription.cancel() }
    chat.downloadModel(candidate.model)
    await fulfillment(of: [started], timeout: 3)
    XCTAssertEqual(chat.state, .benchmarking)
    XCTAssertTrue(chat.isBusy)
    XCTAssertEqual(chat.installedModel?.id, candidate.id)
    chat.submit("Must not start while benchmarking")
    chat.downloadModel(catalog.models[0])
    XCTAssertTrue(chat.messages.isEmpty)
    let downloads = await engine.downloadCount
    XCTAssertEqual(downloads, 1)
    await engine.finish(benchmark(model: candidate.model, hardware: mac, speed: 4).metrics)
    await fulfillment(of: [finished], timeout: 3)
    XCTAssertEqual(chat.installedModel?.id, candidate.id)
    XCTAssertEqual(advisor.measurements.count, 1)
    XCTAssertTrue(try XCTUnwrap(advisor.latestBenchmark(for: chat.installedModel)).underperformed)
    XCTAssertFalse(chat.isBusy)
  }

  @MainActor
  func testBenchmarkFailureAndCancellationKeepVerifiedInstallationUsable() async throws {
    for cancel in [false, true] {
      let root = try temporaryDirectory()
      let mac = hardware()
      let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in mac })
      await advisor.detectHardware()
      let started = expectation(description: "Benchmark started")
      let engine = SelectionWorkflowEngine(started: { started.fulfill() })
      let chat = LocalChatViewModel(engine: engine, modelAdvisor: advisor,
        sessionStore: ChatSessionStore(applicationSupportDirectory: root))
      let finished = expectation(description: "Benchmark error acknowledged")
      let subscription = chat.$state.dropFirst().sink { if $0 == .idle { finished.fulfill() } }
      chat.downloadModel(catalog.models[0])
      await fulfillment(of: [started], timeout: 3)
      if cancel { chat.cancelInstallation() }
      await engine.finish(nil)
      await fulfillment(of: [finished], timeout: 3)
      subscription.cancel()
      XCTAssertNotNil(chat.installedModel)
      XCTAssertFalse(chat.isBusy)
      XCTAssertTrue(advisor.measurements.isEmpty)
      XCTAssertTrue(chat.benchmarkNotice?.contains(cancel ? "cancelled" : "Performance check:") == true)
    }
  }

  @MainActor
  func testDownloadConfirmationRechecksCurrentResources() async throws {
    let root = try temporaryDirectory()
    var mac = hardware()
    mac.availableDiskBytes = 0
    let current = mac
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in current })
    do {
      _ = try await advisor.confirmDownload(catalog.models[0], installedModels: [])
      XCTFail("Must reject a model when disk space is no longer available")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("resources"))
    }
  }

  @MainActor
  func testRetiredGemmaPackageIsNotOfferedForNewDownload() async throws {
    let root = try temporaryDirectory()
    let profile = hardware(memory: 24)
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in profile })
    let gemma = try XCTUnwrap(LegacyModelFixtures.models.first { $0.id == "gemma-4-12b-it-qat-q4_0-gguf" })

    do {
      _ = try await advisor.confirmDownload(gemma, installedModels: [])
      XCTFail("Retired packages must not be offered for new installation")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("resources"))
    }
  }

  @MainActor
  private func render<V: View>(_ root: V, size: NSSize, name: String, roundedWindow: Bool = false) throws {
    let view = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: image)
    if roundedWindow {
      for (x, y) in [(0, 0), (image.pixelsWide - 1, 0), (0, image.pixelsHigh - 1), (image.pixelsWide - 1, image.pixelsHigh - 1)] {
        XCTAssertLessThan(try XCTUnwrap(image.colorAt(x: x, y: y)).alphaComponent, 0.05, "Window corners must stay transparent")
      }
      XCTAssertGreaterThan(try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)).alphaComponent, 0.95)
    }
    let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
    try png.write(to: FileManager.default.temporaryDirectory.appending(path: "\(name).png"))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testVerifiedDownloadUsesExistingAtomicInstallerAndFailuresKeepOldModel() async throws {
    let bytes = Data("GGUF test transport bytes".utf8)
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    for scenario in ["valid", "checksum", "truncated", "overlong", "http", "disk"] {
      let root = try temporaryDirectory()
      let store = LocalModelInstallationStore(modelsDirectory: root.appending(path: "models"))
      let source = root.appending(path: "old.gguf")
      try Data("old model".utf8).write(to: source)
      let old = try store.install(LocalModel(id: "old", displayName: "Old", fileURL: source))
      var components = try XCTUnwrap(URLComponents(url: catalog.models[0].downloadURL, resolvingAgainstBaseURL: false))
      components.query = "fixture=\(UUID())"
      let url = try XCTUnwrap(components.url)
      let descriptor = try modifying(catalog.models[0], [
        "downloadURL": url.absoluteString, "expectedByteCount": bytes.count,
        "checksumSHA256": scenario == "checksum" ? String(repeating: "0", count: 64) : hash,
      ])
      let body = scenario == "truncated" ? bytes.dropLast() : scenario == "overlong" ? bytes + Data([0]) : bytes
      ModelTransportProtocol.responses.set(url, body: Data(body), status: scenario == "http" ? 503 : 200)
      let session = fixtureSession()
      defer { session.invalidateAndCancel() }
      let mac = hardware()
      let download = LocalModelCatalog(installationStore: store, session: session,
        detectHardware: { _ in mac }, availableDisk: { _ in scenario == "disk" ? 0 : 200 * LocalHardwareProfile.gib })
      do {
        if scenario == "disk" {
          _ = try await download.download(descriptor) { _ in }
          XCTFail("Expected real disk gate to reject installation")
        }
        let staged = root.appending(path: "verified.gguf")
        try await VerifiedModelArtifact(url: url, expectedByteCount: Int64(bytes.count),
          checksumSHA256: descriptor.checksumSHA256).download(to: staged, session: session) { _ in }
        let installed = try store.install(LocalModel(id: descriptor.id, displayName: descriptor.displayName,
          fileURL: staged, catalogDescriptor: descriptor))
        XCTAssertEqual(scenario, "valid")
        XCTAssertEqual(try Data(contentsOf: installed.fileURL), bytes)
        XCTAssertEqual(installed.catalogDescriptor, descriptor)
        XCTAssertEqual(store.installedModel(), installed)
      } catch {
        XCTAssertNotEqual(scenario, "valid", "\(error)")
        XCTAssertEqual(store.installedModel(), old)
      }
      XCTAssertEqual(try Data(contentsOf: old.fileURL), Data("old model".utf8))
      let files = try FileManager.default.contentsOfDirectory(atPath: store.modelsDirectoryURL.path)
      XCTAssertFalse(files.contains { $0.hasPrefix(".downloading") || $0.hasPrefix(".installing") })
    }
  }

  func testRemoteRefreshCachesOnlyVerifiedUpdatesAndRetainsCacheAfterFailure() async throws {
    let root = try temporaryDirectory()
    let key = Curve25519.Signing.PrivateKey()
    let url = URL(string: "https://example.com/\(UUID())/catalog.json")!
    let trust = LocalCatalogTrust(url: url, publicKey: key.publicKey.rawRepresentation)
    let session = fixtureSession()
    defer { session.invalidateAndCancel() }
    let updater = LocalCatalogUpdater(directory: root, trust: trust, session: session)
    let next = LocalModelManifest(version: catalog.version + 1, models: catalog.models)
    ModelTransportProtocol.responses.set(url, body: try signedData(next, key: key))
    let refreshed = await updater.catalog(force: true)
    XCTAssertEqual(refreshed, next)
    let cacheURL = root.appending(path: "signed-model-catalog.json")
    let cache = try Data(contentsOf: cacheURL)
    ModelTransportProtocol.responses.set(url, body: Data("invalid signature".utf8))
    let untrusted = await updater.catalog(force: true)
    XCTAssertEqual(untrusted, next)
    XCTAssertEqual(try Data(contentsOf: cacheURL), cache)
    ModelTransportProtocol.responses.set(url, body: Data(), status: 503)
    let unavailable = await updater.catalog(force: true)
    XCTAssertEqual(unavailable, next)
    XCTAssertEqual(try Data(contentsOf: cacheURL), cache)
    ModelTransportProtocol.responses.set(url, body: try signedData(catalog, key: key))
    let rollback = await updater.catalog(force: true)
    XCTAssertEqual(rollback, next)
  }

  private func fixtureSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ModelTransportProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func hardware(memory: Int = 16) -> LocalHardwareProfile {
    LocalHardwareProfile(physicalMemory: Int64(memory) * gib, isAppleSilicon: true, hasMetal: true,
      hasUnifiedMemory: true, chip: "Fixture chip", device: "Fixture Mac", cpuCount: 12, performanceCPUCount: 8,
      availableDiskBytes: 200 * gib, metalRecommendedWorkingSet: nil, metalMaximumBufferLength: 8 * gib, lowPowerMode: false)
  }

  private func modifying(_ model: LocalModelDescriptor, _ fields: [String: Any]) throws -> LocalModelDescriptor {
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
    json.merge(fields) { _, new in new }
    return try JSONDecoder().decode(LocalModelDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
  }

  private func benchmark(model: LocalModelDescriptor, hardware: LocalHardwareProfile, speed: Double = 20,
                         memory: Int64 = 2_000_000_000, promptSpeed: Double = 100) -> LocalModelBenchmark {
    LocalModelBenchmark(version: 1, llamaBuild: model.runtimeBuild ?? LocalModelCompatibility.llamaBuild,
      hardwareFingerprint: hardware.fingerprint, lowPowerMode: hardware.lowPowerMode,
      modelID: model.id, modelChecksum: model.checksumSHA256, modelByteCount: model.expectedByteCount,
      parameterBillions: model.parameterBillions, architecture: model.architecture, contextSize: model.recommendedContextSize,
      recordedAt: .now, metrics: LocalBenchmarkMetrics(timeToFirstToken: 1,
        generationTokensPerSecond: speed, promptTokensPerSecond: promptSpeed, peakMemoryBytes: memory,
        promptTokenCount: 140, generatedTokenCount: 64, modelLoadSeconds: 0.5),
      predictedTokensPerSecond: 20, predictedTimeToFirstToken: 1)
  }

  private func signedData(_ manifest: LocalModelManifest, key: Curve25519.Signing.PrivateKey) throws -> Data {
    let payload = try JSONEncoder().encode(manifest)
    return try JSONEncoder().encode(SignedLocalModelCatalog(payload: payload, signature: key.signature(for: payload)))
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "LocalSelectionTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
}

private actor SelectionTestEngine: LocalModelEngine {
  func install(_ model: LocalModel) async throws {}
  func installedModel() async -> LocalModel? { nil }
  func installedModels() async -> [LocalModel] { [] }
  func selectModel(id: String) async throws {}
  func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel {
    throw LocalInferenceError.invalidModelFile
  }
  nonisolated func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.finish() }
  }
  func unload() async {}
}

private actor SelectionWorkflowEngine: LocalModelEngine {
  var model: LocalModel?
  var downloadCount = 0
  let started: @Sendable () -> Void
  private var continuation: CheckedContinuation<LocalBenchmarkMetrics?, Never>?

  init(started: @escaping @Sendable () -> Void) { self.started = started }
  func install(_ model: LocalModel) async throws { self.model = model }
  func installedModel() async -> LocalModel? { model }
  func installedModels() async -> [LocalModel] { model.map { [$0] } ?? [] }
  func selectModel(id: String) async throws {}
  func download(_ descriptor: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel {
    downloadCount += 1
    let model = LocalModel(id: descriptor.id, displayName: descriptor.displayName,
      fileURL: URL(fileURLWithPath: "/tmp/selection-fixture.gguf"), catalogDescriptor: descriptor)
    self.model = model
    return model
  }
  func benchmark() async throws -> LocalBenchmarkMetrics? {
    let result = await withCheckedContinuation { continuation in
      self.continuation = continuation
      started()
    }
    try Task.checkCancellation()
    guard let result else { throw LocalInferenceError.bridgeFailure("Fixture benchmark failed") }
    return result
  }
  func finish(_ result: LocalBenchmarkMetrics?) {
    continuation?.resume(returning: result)
    continuation = nil
  }
  nonisolated func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.finish() }
  }
  func unload() async {}
}

private final class ModelTransportProtocol: URLProtocol, @unchecked Sendable {
  static let responses = Responses()

  final class Responses: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL: (Data, Int)] = [:]
    func set(_ url: URL, body: Data, status: Int = 200) {
      lock.lock()
      defer { lock.unlock() }
      items[url] = (body, status)
    }
    func take(_ url: URL) -> (Data, Int)? {
      lock.lock()
      defer { lock.unlock() }
      return items.removeValue(forKey: url)
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url, let (body, status) = Self.responses.take(url),
          let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

extension LocalModelSelectionTests {
  @MainActor
  private func welcomeDefaults() throws -> UserDefaults {
    let name = "WelcomeSetupTests-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    return defaults
  }

  @MainActor
  func testWelcomeResumesIncompleteSetupAndCompletionPersists() throws {
    let defaults = try welcomeDefaults()
    let setup = WelcomeSetup(defaults: defaults)
    setup.start(hasInstalledModels: false)
    XCTAssertTrue(setup.isPresented)
    XCTAssertEqual(setup.step, .welcome)
    setup.step = .connections
    let resumed = WelcomeSetup(defaults: defaults)
    resumed.start(hasInstalledModels: true)
    XCTAssertTrue(resumed.isPresented)
    XCTAssertEqual(resumed.step, .connections)
    resumed.finish(takeTour: false)
    XCTAssertFalse(resumed.isPresented)
    XCTAssertNil(resumed.tour)
    XCTAssertNil(defaults.object(forKey: WelcomeSetup.progressKey))
    let completed = WelcomeSetup(defaults: defaults)
    completed.start(hasInstalledModels: false)
    XCTAssertFalse(completed.isPresented)
  }

  @MainActor
  func testWelcomeMigrationAndReplayPreserveExistingPreferences() throws {
    for hasModel in [false, true] {
      let defaults = try welcomeDefaults()
      defaults.set(!hasModel, forKey: "localModelOnboardingDismissed")
      defaults.set("cloud", forKey: StartPreferences.modeKey)
      let setup = WelcomeSetup(defaults: defaults)
      setup.start(hasInstalledModels: hasModel)
      XCTAssertFalse(setup.isPresented)
      setup.replay()
      XCTAssertTrue(setup.isPresented)
      XCTAssertEqual(setup.step, .welcome)
      XCTAssertEqual(defaults.string(forKey: StartPreferences.modeKey), "cloud")
      setup.finish(takeTour: true)
      for step in WelcomeTourStep.allCases {
        XCTAssertEqual(setup.tour, step)
        setup.nextTourStep()
      }
      XCTAssertNil(setup.tour)
      setup.replay()
      setup.finish(takeTour: true)
      setup.endTour()
      XCTAssertNil(setup.tour)
    }
  }

  @MainActor
  func testWelcomeShowsAtMostThreeSafeUniqueChoicesWithRecommendationFirst() {
    for memory in [4, 8, 16, 32, 128] {
      let recommendations = LocalModelSelector.select(manifest: catalog, hardware: hardware(memory: memory))
      let choices = WelcomeSetup.choices(recommendations)
      XCTAssertEqual(choices.count, min(3, recommendations.tierGroups.flatMap { $0.models }.filter(\.fit.canRun).count))
      XCTAssertEqual(Set(choices.map(\.id)).count, choices.count)
      XCTAssertTrue(choices.allSatisfy { $0.fit.canRun })
      if let recommended = recommendations.recommended { XCTAssertEqual(choices.first?.id, recommended.id) }
    }
  }

  @MainActor
  func testWelcomeKeepsChosenModelVisibleAfterRecommendationChanges() throws {
    let recommendations = LocalModelSelector.select(manifest: catalog, hardware: hardware(memory: 128))
    let original = WelcomeSetup.choices(recommendations)
    let chosen = try XCTUnwrap(recommendations.rankedChoices.last { candidate in
      !original.contains { $0.id == candidate.id }
    })
    XCTAssertFalse(original.contains { $0.id == chosen.id })
    let retained = WelcomeSetup.choices(recommendations, preserving: chosen.id)
    XCTAssertEqual(retained.count, 3)
    XCTAssertEqual(retained.first?.id, recommendations.recommended?.id)
    XCTAssertTrue(retained.contains { $0.id == chosen.id })
    let limited = LocalModelSelector.select(manifest: catalog, hardware: hardware(memory: 4))
    XCTAssertTrue(WelcomeSetup.choices(limited, preserving: chosen.id).allSatisfy { $0.fit.canRun })
  }

  @MainActor
  func testWelcomeNextRequiresVerifiedSelectedInstallationOrExplicitSkip() throws {
    let recommendations = LocalModelSelector.select(manifest: catalog, hardware: hardware(memory: 32))
    let selected = try XCTUnwrap(WelcomeSetup.choices(recommendations).first)
    let descriptor = selected.model
    let file = URL(fileURLWithPath: "/tmp/welcome-fixture.gguf")
    let installed = LocalModel(id: selected.id, displayName: descriptor.displayName, fileURL: file,
      catalogDescriptor: descriptor, visionConfiguration: LocalVisionConfiguration(projectorURL: file,
        serverExecutableURL: URL(fileURLWithPath: "/bin/echo"), contextWindow: descriptor.recommendedContextSize,
        packageRevision: descriptor.packageRevision))
    XCTAssertTrue(WelcomeSetup.canContinue(selected: selected, installed: [installed], activeID: selected.id, skipLocal: false, busy: false))
    XCTAssertFalse(WelcomeSetup.canContinue(selected: selected, installed: [installed], activeID: "other", skipLocal: false, busy: false))
    XCTAssertFalse(WelcomeSetup.canContinue(selected: selected, installed: [], activeID: selected.id, skipLocal: false, busy: false))
    var stale = installed
    stale.visionConfiguration?.packageRevision = "old"
    XCTAssertFalse(WelcomeSetup.canContinue(selected: selected, installed: [stale], activeID: selected.id, skipLocal: false, busy: false))
    for busy in [false, true] {
      XCTAssertEqual(WelcomeSetup.canContinue(selected: nil, installed: [], activeID: nil, skipLocal: true, busy: busy), !busy)
    }
    XCTAssertFalse(WelcomeSetup.canContinue(selected: selected, installed: [installed], activeID: selected.id, skipLocal: false, busy: true))
    XCTAssertFalse(WelcomeSetup.canContinue(selected: nil, installed: [], activeID: nil, skipLocal: false, busy: false))
  }

  @MainActor
  func testWelcomeSuppressesLegacyAutomaticModelSheet() async throws {
    let root = try temporaryDirectory()
    let defaults = try welcomeDefaults()
    let mac = hardware()
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, defaults: defaults, trust: nil, detect: { _ in mac })
    await advisor.start(installedModels: [], presentOnboarding: false)
    XCTAssertNotNil(advisor.hardware)
    XCTAssertFalse(advisor.isOnboardingPresented)
    await advisor.replayOnboarding()
    XCTAssertTrue(advisor.isOnboardingPresented)
  }

  @MainActor
  func testWelcomeAnimationIncludesAllFiveOriginalLetters() throws {
    XCTAssertEqual(EnigmaHelloLetter.all.count, 5)
    XCTAssertGreaterThan(EnigmaHelloLetter.all.flatMap(\.cols).flatMap(\.rows).count, 1000)
    XCTAssertTrue(EnigmaHelloLetter.all.flatMap(\.cols).flatMap(\.rows).allSatisfy {
      $0.char.count == 1 && $0.opacity > 0 && $0.opacity <= 1 && $0.y.isFinite
    })
  }

  @MainActor
  func testChatBecomesEditableImmediatelyAfterEveryWelcomeExit() async throws {
    let root = try temporaryDirectory()
    let defaults = try welcomeDefaults()
    let profile = hardware(memory: 32)
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, defaults: defaults, trust: nil, detect: { _ in profile })
    let chat = LocalChatViewModel(engine: SelectionTestEngine(), sessionStore: ChatSessionStore(applicationSupportDirectory: root))
    let credentials = ScreenTestCredentialStore()
    let cloud = CloudSettingsModel(credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: ScreenTestTransport(), cacheDirectory: root),
      preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false })
    let setup = WelcomeSetup(defaults: defaults)
    let preferences = StartPreferences(defaults: defaults)
    preferences.mode = .cloud
    let appearance = GlassAppearanceSettings(defaults: defaults)
    let view = NSHostingView(rootView: AppShellView(glassAppearance: appearance, cloudSettings: cloud,
      localChat: chat, modelAdvisor: advisor,
      searchSettings: WebSearchSettings(credentials: WelcomeEmptySearchCredentials(), defaults: defaults),
      startPreferences: preferences, welcomeSetup: setup)
      .transaction { $0.disablesAnimations = true })
    let controller = SpotlightPanelController(glassAppearance: appearance, sizeStore: PanelSizeStore(defaults: defaults),
      contentView: view, welcomeSetup: setup)
    controller.show()
    defer { controller.hide() }
    func settle() async throws {
      try await Task.sleep(for: .milliseconds(150))
      view.layoutSubtreeIfNeeded()
    }
    func editor(in parent: NSView) -> SlashCommandTextView? {
      if let editor = parent as? SlashCommandTextView { return editor }
      return parent.subviews.lazy.compactMap { editor(in: $0) }.first
    }
    try await settle()
    for exit in 0..<3 {
      setup.replay()
      try await settle()
      XCTAssertFalse(try XCTUnwrap(editor(in: view)).isEditable)
      setup.finish(takeTour: exit != 0)
      if exit == 1 { setup.endTour() }
      if exit == 2 {
        for _ in WelcomeTourStep.allCases { setup.nextTourStep() }
      }
      try await settle()
      let composer = try XCTUnwrap(editor(in: view))
      XCTAssertTrue(composer.isEditable, "Welcome exit \(exit) must enable the composer")
      XCTAssertTrue(composer.window?.firstResponder === composer, "Welcome exit \(exit) must focus the composer")
      XCTAssertEqual(preferences.mode, .auto)
      // NSView.hitTest takes a point in the receiver's superview coordinates.
      let point = composer.convert(NSPoint(x: composer.bounds.midX, y: composer.bounds.midY), to: view.superview)
      let hit = try XCTUnwrap(view.hitTest(point))
      XCTAssertTrue(hit === composer || hit.isDescendant(of: composer), "Welcome exit \(exit) must allow clicks through to chat; hit \(hit), point \(point)")
      composer.insertText("Ready to chat", replacementRange: NSRange(location: 0, length: composer.string.utf16.count))
      XCTAssertEqual(composer.string, "Ready to chat")
    }
  }

  @MainActor
  func testWelcomeScreensRenderAtMinimumAndDefaultPanelSizes() async throws {
    let root = try temporaryDirectory()
    let defaults = try welcomeDefaults()
    let profile = hardware(memory: 32)
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, defaults: defaults, trust: nil, detect: { _ in profile })
    await advisor.detectHardware()
    let chat = LocalChatViewModel(engine: SelectionTestEngine(), sessionStore: ChatSessionStore(applicationSupportDirectory: root))
    let credentials = ScreenTestCredentialStore()
    let cloud = CloudSettingsModel(credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: ScreenTestTransport(), cacheDirectory: root),
      preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false })
    let search = WebSearchSettings(credentials: WelcomeEmptySearchCredentials(), defaults: defaults)
    let setup = WelcomeSetup(defaults: defaults)
    setup.replay()
    for step in WelcomeSetup.Step.allCases {
      setup.step = step
      for size in [NSSize(width: 640, height: 420), NSSize(width: 1000, height: 780)] {
        try render(WelcomeSetupView(setup: setup, advisor: advisor, chat: chat, cloud: cloud, search: search), size: size, name: "welcome-\(step)-\(Int(size.width))", roundedWindow: true)
      }
    }
    try render(SettingsView(settings: cloud), size: NSSize(width: 820, height: 680), name: "settings-permissions")
    try render(SettingsView(settings: cloud, initialDestination: .selection), size: NSSize(width: 820, height: 680), name: "selection-permissions")
    setup.step = .welcome
    let shell = AppShellView(glassAppearance: GlassAppearanceSettings(defaults: defaults), cloudSettings: cloud,
      localChat: chat, modelAdvisor: advisor, searchSettings: search,
      startPreferences: StartPreferences(defaults: defaults), welcomeSetup: setup)
    try render(shell, size: NSSize(width: 640, height: 420), name: "welcome-window-rounded", roundedWindow: true)
    setup.finish(takeTour: true)
    for sidebar in [false, true] {
      let preferences = StartPreferences(defaults: defaults)
      preferences.showsSidebar = sidebar
      for step in WelcomeTourStep.allCases {
        // Rewind without changing any chat or account state.
        setup.replay()
        setup.finish(takeTour: true)
        for _ in 0..<step.rawValue { setup.nextTourStep() }
        let view = AppShellView(glassAppearance: GlassAppearanceSettings(defaults: defaults), cloudSettings: cloud,
          localChat: chat, modelAdvisor: advisor, searchSettings: search, startPreferences: preferences, welcomeSetup: setup)
        try render(view, size: NSSize(width: 1000, height: 780), name: "welcome-tour-\(step)-\(sidebar)")
        try render(view, size: NSSize(width: 640, height: 420), name: "welcome-tour-small-\(step)-\(sidebar)")
      }
    }
  }
}

private struct WelcomeEmptySearchCredentials: WebSearchCredentialStore {
  func apiKey() throws -> String? { nil }
  func setAPIKey(_ value: String) throws {}
  func removeAPIKey() throws {}
}


// Official publisher GGUF/LFS metadata and llama.cpp b10797 reviewed 2026-09-06.
// See docs/Local-Model-Selection.md for evidence, memory policy and limitations.
// Retired packages are fixtures for decoding and memory-override compatibility only.
private enum LegacyModelFixtures {
  static let models: [LocalModelDescriptor] = [
    LocalModelDescriptor(
      id: "qwen3-vl-4b-instruct-q4-k-m", displayName: "Qwen3-VL 4B Instruct",
      downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/1cd86afb9a95c410a6038ab3b40d8b578c892266/Qwen3VL-4B-Instruct-Q4_K_M.gguf")!,
      expectedByteCount: 2497281664, license: "Apache-2.0", checksumSHA256: "66358cb18bb6b3b1b6675aa412c7a88ef01d228f481184d13668e5201c730a0a",
      revision: "1cd86afb9a95c410a6038ab3b40d8b578c892266", quantization: "Q4_K_M", architecture: "qwen3vl",
      chatTemplate: "qwen3-vl-instruct", minimumLlamaBuild: 10797,
      estimatedRuntimeMemory: LocalModelDescriptor.multimodalMemory(weights: 2497281664, projector: 836180256, parameters: 4, context: 8192),
      largestTensorBytes: LocalHardwareProfile.gib, recommendedContextSize: 8192,
      qualityScore: 76, performanceClass: "General text and visual reasoning", parameterBillions: 4,
      minimumMemory: 12 * LocalHardwareProfile.gib, recommendedMemory: 16 * LocalHardwareProfile.gib,
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/1cd86afb9a95c410a6038ab3b40d8b578c892266/mmproj-Qwen3VL-4B-Instruct-F16.gguf")!,
        expectedByteCount: 836180256, checksumSHA256: "256f3a43bd4205ffef48d6b92715e1e70b5b0e9aef06522584967513a9985331"), runtimeBuild: 10797, publisher: "Alibaba / Qwen", modelSummary: "An efficient Alibaba model for everyday chat, reading screenshots and visual questions."),
    package(id: "gemma-4-12b-it-qat-q4_0-gguf", name: "Google Gemma 4 12B", publisher: "Google",
      summary: "A mid-sized Google model for stronger reasoning, writing and image understanding on higher-memory Macs.", profile: .gemma4_12B, quality: 89, minimumGiB: 32, recommendedGiB: 48,
      revision: "29d097773436b69ff9feafd636ab4cf873786537", model: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/google/gemma-4-12B-it-qat-q4_0-gguf/resolve/29d097773436b69ff9feafd636ab4cf873786537/gemma-4-12b-it-qat-q4_0.gguf")!,
        expectedByteCount: 6975879296, checksumSHA256: "93567e57a8fe10b23569b9d9ec38cd005deedf71e29477c421a4b83f418a538b"),
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/google/gemma-4-12B-it-qat-q4_0-gguf/resolve/29d097773436b69ff9feafd636ab4cf873786537/mmproj-gemma-4-12b-it-qat-q4_0.gguf")!,
        expectedByteCount: 175115616, checksumSHA256: "cb018338a7538a9814d994bfe54644c71eb7ed54e31eae2f721e45fd3c260da7")),
  ]

  private static func package(id: String, name: String, publisher: String, summary: String,
    profile: LocalMultimodalProfile, quality: Double, minimumGiB: Int64, recommendedGiB: Int64,
    revision: String, model: VerifiedModelArtifact, projector: VerifiedModelArtifact) -> LocalModelDescriptor {
    LocalModelDescriptor(id: id, displayName: name, downloadURL: model.url,
      expectedByteCount: model.expectedByteCount, license: "Apache-2.0", checksumSHA256: model.checksumSHA256,
      revision: revision, quantization: profile.quantizations[0], architecture: profile.architecture,
      chatTemplate: profile.chatTemplate, minimumLlamaBuild: LocalVisionRuntime.build,
      estimatedRuntimeMemory: profile.memory(weights: model.expectedByteCount, projector: projector.expectedByteCount, context: 8192),
      largestTensorBytes: (profile.architecture == "gemma4" ? 3 : 1) * LocalHardwareProfile.gib,
      recommendedContextSize: 8192, qualityScore: quality, performanceClass: "General text and visual reasoning",
      parameterBillions: profile.parameters, minimumMemory: minimumGiB * LocalHardwareProfile.gib,
      recommendedMemory: recommendedGiB * LocalHardwareProfile.gib, projector: projector,
      runtimeBuild: LocalVisionRuntime.build, publisher: publisher, modelSummary: summary, inferenceProfile: profile)
  }
}
