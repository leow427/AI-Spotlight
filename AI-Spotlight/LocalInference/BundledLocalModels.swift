import Foundation

// Official Qwen GGUF/LFS metadata and llama.cpp b10797 reviewed 2026-09-06.
// See docs/Local-Model-Selection.md for evidence, memory policy and limitations.
enum BundledLocalModels {
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
        expectedByteCount: 836180256, checksumSHA256: "256f3a43bd4205ffef48d6b92715e1e70b5b0e9aef06522584967513a9985331"), runtimeBuild: 10797),
    LocalModelDescriptor(
      id: "qwen3-vl-8b-instruct-q4-k-m", displayName: "Qwen3-VL 8B Instruct",
      downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-VL-8B-Instruct-GGUF/resolve/f982a07559d4a2f6c8744d840bf6fccab30eea96/Qwen3VL-8B-Instruct-Q4_K_M.gguf")!,
      expectedByteCount: 5027784800, license: "Apache-2.0", checksumSHA256: "67d1659bfe71b89d50b45a4ad1a9e5b997e5bb16ce5da66a6a6167abd569e9e2",
      revision: "f982a07559d4a2f6c8744d840bf6fccab30eea96", quantization: "Q4_K_M", architecture: "qwen3vl",
      chatTemplate: "qwen3-vl-instruct", minimumLlamaBuild: 10797,
      estimatedRuntimeMemory: LocalModelDescriptor.multimodalMemory(weights: 5027784800, projector: 1159029824, parameters: 8, context: 8192),
      largestTensorBytes: LocalHardwareProfile.gib, recommendedContextSize: 8192,
      qualityScore: 84, performanceClass: "General text and visual reasoning", parameterBillions: 8,
      minimumMemory: 24 * LocalHardwareProfile.gib, recommendedMemory: 32 * LocalHardwareProfile.gib,
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/Qwen/Qwen3-VL-8B-Instruct-GGUF/resolve/f982a07559d4a2f6c8744d840bf6fccab30eea96/mmproj-Qwen3VL-8B-Instruct-F16.gguf")!,
        expectedByteCount: 1159029824, checksumSHA256: "ca524100ebf825c9a870db1c580d03879e0da0ab2541697e2458e64891cf9d38"), runtimeBuild: 10797),
    LocalModelDescriptor(
      id: "qwen3-vl-32b-instruct-q4-k-m", displayName: "Qwen3-VL 32B Instruct",
      downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-VL-32B-Instruct-GGUF/resolve/e3e1fe0c76de7ee58ea65db420c643adfe2e457c/Qwen3VL-32B-Instruct-Q4_K_M.gguf")!,
      expectedByteCount: 19762150432, license: "Apache-2.0", checksumSHA256: "5cf0136e721d6294718ec71fd8c93b17ab5dd4e2714d6079e83fa46571ad94c8",
      revision: "e3e1fe0c76de7ee58ea65db420c643adfe2e457c", quantization: "Q4_K_M", architecture: "qwen3vl",
      chatTemplate: "qwen3-vl-instruct", minimumLlamaBuild: 10797,
      estimatedRuntimeMemory: LocalModelDescriptor.multimodalMemory(weights: 19762150432, projector: 1196795040, parameters: 32, context: 8192),
      largestTensorBytes: LocalHardwareProfile.gib, recommendedContextSize: 8192,
      qualityScore: 90, performanceClass: "General text and visual reasoning", parameterBillions: 32,
      minimumMemory: 64 * LocalHardwareProfile.gib, recommendedMemory: 64 * LocalHardwareProfile.gib,
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/Qwen/Qwen3-VL-32B-Instruct-GGUF/resolve/e3e1fe0c76de7ee58ea65db420c643adfe2e457c/mmproj-Qwen3VL-32B-Instruct-F16.gguf")!,
        expectedByteCount: 1196795040, checksumSHA256: "8617824839df91f84b4840ad5084dcf50a1403a435a1f4cfc4d8c84ce6cac2fc"), runtimeBuild: 10797),
  ]
}
