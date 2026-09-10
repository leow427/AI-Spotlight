import Foundation

// Exact GGUF and projector metadata reviewed 2026-09-10. See docs/Local-Model-Selection.md.
enum BundledLocalModels {
  static let models: [LocalModelDescriptor] = [
    package(id: "smolvlm2-2.2b-q8_0", name: "SmolVLM2 2.2B", publisher: "Hugging Face", profile: .smolVLM2,
      quantization: "Q8_0", minimumGiB: 16, quality: 65, memoryRange: "3.5–4.5", audio: false,
      revision: "1bc3c9f74ceafd4c8d4411cc9cf188bba3798f91",
      model: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/ggml-org/SmolVLM2-2.2B-Instruct-GGUF/resolve/1bc3c9f74ceafd4c8d4411cc9cf188bba3798f91/SmolVLM2-2.2B-Instruct-Q8_0.gguf")!, expectedByteCount: 1927933984, checksumSHA256: "c850ffa51b0708be8911766e1d35e8e71365e987c8efb2513a7f237baade074f"),
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/ggml-org/SmolVLM2-2.2B-Instruct-GGUF/resolve/1bc3c9f74ceafd4c8d4411cc9cf188bba3798f91/mmproj-SmolVLM2-2.2B-Instruct-Q8_0.gguf")!, expectedByteCount: 592523200, checksumSHA256: "ae07ea1facd07dd3230c4483b63e8cda96c6944ad2481f33d531f79e892dd024")),
    package(id: "qwen3.5-4b-q4_k_m", name: "Qwen3.5 4B", publisher: "Alibaba / Qwen", profile: .qwen35_4B,
      quantization: "Q4_K_M", minimumGiB: 16, quality: 80, memoryRange: "4–6", audio: false,
      revision: "e87f176479d0855a907a41277aca2f8ee7a09523",
      model: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf")!, expectedByteCount: 2740937888, checksumSHA256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4"),
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/mmproj-F16.gguf")!, expectedByteCount: 672423616, checksumSHA256: "cd88edcf8d031894960bb0c9c5b9b7e1fea6ebee02b9f7ce925a00d12891f864")),
    package(id: "qwen3.5-4b-q5_k_m", name: "Qwen3.5 4B", publisher: "Alibaba / Qwen", profile: .qwen35_4B,
      quantization: "Q5_K_M", minimumGiB: 24, quality: 80, memoryRange: "4.5–6", audio: false,
      revision: "e87f176479d0855a907a41277aca2f8ee7a09523",
      model: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q5_K_M.gguf")!, expectedByteCount: 3143656608, checksumSHA256: "8814232b85594dcd46c50e5b8b29324a7efe9e746edbe8a3d1df3d3fce7aad39"),
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/mmproj-F16.gguf")!, expectedByteCount: 672423616, checksumSHA256: "cd88edcf8d031894960bb0c9c5b9b7e1fea6ebee02b9f7ce925a00d12891f864")),
    package(id: "qwen3.5-4b-q8_0", name: "Qwen3.5 4B", publisher: "Alibaba / Qwen", profile: .qwen35_4B,
      quantization: "Q8_0", minimumGiB: 32, quality: 80, memoryRange: "6–8", audio: false,
      revision: "e87f176479d0855a907a41277aca2f8ee7a09523",
      model: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q8_0.gguf")!, expectedByteCount: 4482403488, checksumSHA256: "10cc391b403021dd11c614679d2fd92f611c3681d29e29651b717316965d61e1"),
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/mmproj-F16.gguf")!, expectedByteCount: 672423616, checksumSHA256: "cd88edcf8d031894960bb0c9c5b9b7e1fea6ebee02b9f7ce925a00d12891f864")),
    package(id: "qwen3.5-9b-q5_k_m", name: "Qwen3.5 9B", publisher: "Alibaba / Qwen", profile: .qwen35_9B,
      quantization: "Q5_K_M", minimumGiB: 24, quality: 88, memoryRange: "8.5–11", audio: false,
      revision: "3885219b6810b007914f3a7950a8d1b469d598a5",
      model: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/3885219b6810b007914f3a7950a8d1b469d598a5/Qwen3.5-9B-Q5_K_M.gguf")!, expectedByteCount: 6577841376, checksumSHA256: "dc2a39aef291f91a9116ad214058da0d86eb648743a124bd8c333787c4b9c91c"),
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/3885219b6810b007914f3a7950a8d1b469d598a5/mmproj-F16.gguf")!, expectedByteCount: 918166080, checksumSHA256: "f70dc3509053962b0d0d3ee8a7eacebf5d60aa560cad78254ae8698516ae029f")),
    package(id: "gemma-4-e4b-q4_k_m", name: "Gemma 4 E4B", publisher: "Google", profile: .gemma4E4B,
      quantization: "Q4_K_M", minimumGiB: 16, quality: 86, memoryRange: "7–9", audio: true,
      revision: "bfc15c382204943c3a8fff0c750b94ae2364d7a3",
      model: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/bfc15c382204943c3a8fff0c750b94ae2364d7a3/gemma-4-E4B-it-Q4_K_M.gguf")!, expectedByteCount: 4977171584, checksumSHA256: "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87"),
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/bfc15c382204943c3a8fff0c750b94ae2364d7a3/mmproj-F16.gguf")!, expectedByteCount: 990372672, checksumSHA256: "ddf46c21d7078e95338cfc22306b19b276a29a5ad089023449dd54d4b6170a51")),
    package(id: "gemma-4-12b-q5_k_m", name: "Gemma 4 12B", publisher: "Google", profile: .gemma4_12B,
      quantization: "Q5_K_M", minimumGiB: 24, quality: 89, memoryRange: "10–13", audio: true,
      revision: "fc034cfff751157913579611efad8462ac1be606",
      model: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/fc034cfff751157913579611efad8462ac1be606/gemma-4-12b-it-Q5_K_M.gguf")!, expectedByteCount: 8413576000, checksumSHA256: "32c554c7d1338a23837ae39b3db482213a4a642f96df3b2619f516a2375d16cd"),
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/fc034cfff751157913579611efad8462ac1be606/mmproj-F16.gguf")!, expectedByteCount: 175115840, checksumSHA256: "91f086971e56d7a7d8d39e271873fccdb49541bd259d6e02c401a4f1cb7a219e")),
    package(id: "gemma-4-26b-a4b-q4_k_m", name: "Gemma 4 26B-A4B", publisher: "Google", profile: .gemma4A4B,
      quantization: "Q4_K_M", minimumGiB: 32, quality: 93, memoryRange: "21–25", audio: false,
      revision: "10f3b41bcf8d3047f4e136e7197ffc2dd1654c9d",
      model: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/bartowski/google_gemma-4-26B-A4B-it-GGUF/resolve/10f3b41bcf8d3047f4e136e7197ffc2dd1654c9d/google_gemma-4-26B-A4B-it-Q4_K_M.gguf")!, expectedByteCount: 17035039872, checksumSHA256: "a07f72221e8e3f77455ab0d7f7652d01a9f63c262b954aa6932a53275a0e895a"),
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/bartowski/google_gemma-4-26B-A4B-it-GGUF/resolve/10f3b41bcf8d3047f4e136e7197ffc2dd1654c9d/mmproj-google_gemma-4-26B-A4B-it-f16.gguf")!, expectedByteCount: 1193058528, checksumSHA256: "41cdabd1e8066e983ee6c288eb0117777376223ee0279cadcd67b2295e4d975f")),
    package(id: "ministral-3-8b-q4_k_m", name: "Ministral 3 8B", publisher: "Mistral AI", profile: .ministral8B,
      quantization: "Q4_K_M", minimumGiB: 16, quality: 84, memoryRange: "7–10", audio: false,
      revision: "0102285ad796bd99af90f58de616092e5630e970",
      model: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/mistralai/Ministral-3-8B-Instruct-2512-GGUF/resolve/0102285ad796bd99af90f58de616092e5630e970/Ministral-3-8B-Instruct-2512-Q4_K_M.gguf")!, expectedByteCount: 5198911904, checksumSHA256: "33e7a72cf5e6e2cfc2f2847075acc013d68bba023e35310cef86b5cf8fdca761"),
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/mistralai/Ministral-3-8B-Instruct-2512-GGUF/resolve/0102285ad796bd99af90f58de616092e5630e970/Ministral-3-8B-Instruct-2512-BF16-mmproj.gguf")!, expectedByteCount: 858283168, checksumSHA256: "e799380f596d152ff4026a72d409ecc89c96cd437676804bc3f2ab3bd6b486ec")),
    package(id: "ministral-3-14b-q5_k_m", name: "Ministral 3 14B", publisher: "Mistral AI", profile: .ministral14B,
      quantization: "Q5_K_M", minimumGiB: 24, quality: 90, memoryRange: "12–15", audio: false,
      revision: "74fac473c43357d7fb2671713608183cc72496d0",
      model: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/mistralai/Ministral-3-14B-Instruct-2512-GGUF/resolve/74fac473c43357d7fb2671713608183cc72496d0/Ministral-3-14B-Instruct-2512-Q5_K_M.gguf")!, expectedByteCount: 9621091904, checksumSHA256: "f16fef77021df0d4c22e69140a2038478370492f51867b6237699918ae711000"),
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/mistralai/Ministral-3-14B-Instruct-2512-GGUF/resolve/74fac473c43357d7fb2671713608183cc72496d0/Ministral-3-14B-Instruct-2512-BF16-mmproj.gguf")!, expectedByteCount: 879258784, checksumSHA256: "ab7616148b7081030fd38e410c9213ce8346a8b0588291c8ca279058e78cfae7")),
    package(id: "ministral-3-14b-q8_0", name: "Ministral 3 14B", publisher: "Mistral AI", profile: .ministral14B,
      quantization: "Q8_0", minimumGiB: 32, quality: 90, memoryRange: "17–21", audio: false,
      revision: "74fac473c43357d7fb2671713608183cc72496d0",
      model: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/mistralai/Ministral-3-14B-Instruct-2512-GGUF/resolve/74fac473c43357d7fb2671713608183cc72496d0/Ministral-3-14B-Instruct-2512-Q8_0.gguf")!, expectedByteCount: 14359836224, checksumSHA256: "8122acc8df446039d41dd9650dabb024d3c6b8dae6eff336d28ac2bddd3bbc13"),
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/mistralai/Ministral-3-14B-Instruct-2512-GGUF/resolve/74fac473c43357d7fb2671713608183cc72496d0/Ministral-3-14B-Instruct-2512-BF16-mmproj.gguf")!, expectedByteCount: 879258784, checksumSHA256: "ab7616148b7081030fd38e410c9213ce8346a8b0588291c8ca279058e78cfae7")),
    package(id: "minicpm-o-4.5-q4_k_m", name: "MiniCPM-o 4.5", publisher: "OpenBMB", profile: .miniCPMO45,
      quantization: "Q4_K_M", minimumGiB: 16, quality: 87, memoryRange: "8–11", audio: true,
      revision: "db25077c33951fe163b42986fba0132e279872a2",
      model: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/openbmb/MiniCPM-o-4_5-gguf/resolve/db25077c33951fe163b42986fba0132e279872a2/MiniCPM-o-4_5-Q4_K_M.gguf")!, expectedByteCount: 5026714400, checksumSHA256: "1237a97ee081b8abebc47aa7dad565701e8f5f904cdc92f6723ac4281bbc0932"),
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/openbmb/MiniCPM-o-4_5-gguf/resolve/db25077c33951fe163b42986fba0132e279872a2/vision/MiniCPM-o-4_5-vision-F16.gguf")!, expectedByteCount: 1095113184, checksumSHA256: "1453678cc4e4fe18de241952962e234f265cb8dda780773526103ab8ba82f421")),
    package(id: "minicpm-o-4.5-q5_k_m", name: "MiniCPM-o 4.5", publisher: "OpenBMB", profile: .miniCPMO45,
      quantization: "Q5_K_M", minimumGiB: 24, quality: 87, memoryRange: "9–13", audio: true,
      revision: "db25077c33951fe163b42986fba0132e279872a2",
      model: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/openbmb/MiniCPM-o-4_5-gguf/resolve/db25077c33951fe163b42986fba0132e279872a2/MiniCPM-o-4_5-Q5_K_M.gguf")!, expectedByteCount: 5849946912, checksumSHA256: "5d32e7569f2ef9c61de81a4fba3890a225240a5cf753e0348f5889dbf44ea434"),
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/openbmb/MiniCPM-o-4_5-gguf/resolve/db25077c33951fe163b42986fba0132e279872a2/vision/MiniCPM-o-4_5-vision-F16.gguf")!, expectedByteCount: 1095113184, checksumSHA256: "1453678cc4e4fe18de241952962e234f265cb8dda780773526103ab8ba82f421")),
  ]

  private static func summary(for profile: LocalMultimodalProfile) -> String {
    switch profile {
    case .smolVLM2: "A compact model for quick image questions and everyday conversation."
    case .qwen35_4B: "Efficient reasoning, writing and screenshot understanding."
    case .qwen35_9B: "More capacity for detailed reasoning and document understanding."
    case .gemma4E4B: "A versatile model for everyday writing, reasoning and visual questions."
    case .gemma4_12B: "Stronger reasoning and image understanding for demanding questions."
    case .gemma4A4B: "A larger mixture-of-experts model for complex text and visual reasoning."
    case .ministral8B: "Multilingual conversation, instruction following and screenshot questions."
    case .ministral14B: "Richer explanations and visual reasoning, with more memory required."
    case .miniCPMO45: "An omnimodal model for documents, visual reasoning and spoken conversation."
    default: "A model for conversation and visual questions."
    }
  }

  private static func package(id: String, name: String, publisher: String, profile: LocalMultimodalProfile,
    quantization: String, minimumGiB: Int64, quality: Double, memoryRange: String, audio: Bool,
    revision: String, model: VerifiedModelArtifact, projector: VerifiedModelArtifact) -> LocalModelDescriptor {
    let memory = profile.memory(weights: model.expectedByteCount, projector: projector.expectedByteCount, context: 8192)
    return LocalModelDescriptor(id: id, displayName: name, downloadURL: model.url,
      expectedByteCount: model.expectedByteCount, license: "Apache-2.0", checksumSHA256: model.checksumSHA256,
      revision: revision, quantization: quantization, architecture: profile.architecture,
      chatTemplate: profile.chatTemplate, minimumLlamaBuild: LocalVisionRuntime.build,
      estimatedRuntimeMemory: memory,
      largestTensorBytes: (profile.architecture == "gemma4" ? 3 : 1) * LocalHardwareProfile.gib,
      recommendedContextSize: 8192, qualityScore: quality,
      performanceClass: audio ? "Vision + Audio model · Text and images in Enigma" : "Vision",
      parameterBillions: profile.parameters, minimumMemory: max(memory, minimumGiB * LocalHardwareProfile.gib),
      recommendedMemory: max(memory, minimumGiB * LocalHardwareProfile.gib), projector: projector,
      runtimeBuild: LocalVisionRuntime.build, publisher: publisher,
      modelSummary: summary(for: profile), inferenceProfile: profile,
      advertisedMemoryRange: memoryRange, modelSupportsAudio: audio)
  }
}

/// Hardware catalogue membership is editorial; admission still checks actual resources.
enum LocalModelWeight: String, CaseIterable, Sendable {
  case lightweight = "Lightweight", middleweight = "Middleweight", heavyweight = "Heavyweight"
}

enum LocalModelTiers {
  static func choices(memory: Int64) -> [(LocalModelWeight, [String])] {
    let gib = LocalHardwareProfile.gib
    if memory < 24 * gib {
      return [(.lightweight, ["smolvlm2-2.2b-q8_0"]),
        (.middleweight, ["qwen3.5-4b-q4_k_m", "gemma-4-e4b-q4_k_m"]),
        (.heavyweight, ["ministral-3-8b-q4_k_m", "minicpm-o-4.5-q4_k_m"])]
    }
    if memory < 32 * gib {
      return [(.lightweight, ["qwen3.5-4b-q5_k_m"]),
        (.middleweight, ["qwen3.5-9b-q5_k_m", "minicpm-o-4.5-q5_k_m"]),
        (.heavyweight, ["gemma-4-12b-q5_k_m", "ministral-3-14b-q5_k_m"])]
    }
    return [(.lightweight, ["qwen3.5-4b-q8_0"]),
      (.middleweight, ["minicpm-o-4.5-q5_k_m", "gemma-4-12b-q5_k_m"]),
      (.heavyweight, ["ministral-3-14b-q8_0", "gemma-4-26b-a4b-q4_k_m"])]
  }
}
