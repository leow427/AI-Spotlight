#ifndef AIS_LLAMA_BRIDGE_H
#define AIS_LLAMA_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void * AISLlamaEngineHandle;

typedef struct {
  const char * role;
  const char * content;
} AISLlamaChatMessage;

// Applies the same native template formatter used by inference. Returns the
// required byte count (excluding NUL), or -1 on failure. A null buffer measures.
int32_t AISLlamaFormatChat(
  const char * chat_template,
  const AISLlamaChatMessage * messages,
  int32_t message_count,
  char * buffer,
  int32_t buffer_capacity
);

int32_t AISLlamaEngineContextSize(AISLlamaEngineHandle engine);

// Counts the selected model's fully formatted/tokenized conversation, including
// special tokens. Does not decode tokens or change the engine's KV state.
int32_t AISLlamaEngineCountChatTokens(
  AISLlamaEngineHandle engine,
  const AISLlamaChatMessage * messages,
  int32_t message_count
);

AISLlamaEngineHandle AISLlamaEngineCreate(
  const char * model_path,
  int32_t context_size
);

void AISLlamaEngineDestroy(AISLlamaEngineHandle engine);

bool AISLlamaEngineBeginCompletion(
  AISLlamaEngineHandle engine,
  const AISLlamaChatMessage * messages,
  int32_t message_count,
  int32_t maximum_token_count,
  float temperature
);

// Returns 1 for a token, 0 when generation is complete, and -1 on failure.
int32_t AISLlamaEngineNextToken(
  AISLlamaEngineHandle engine,
  uint8_t * token_bytes,
  int32_t token_capacity,
  int32_t * token_byte_count
);

// Total current process memory, including mapped weights and Metal allocations.
uint64_t AISLlamaProcessMemoryBytes(void);

const char * AISLlamaBridgeLastError(void);

#ifdef __cplusplus
}
#endif

#endif
