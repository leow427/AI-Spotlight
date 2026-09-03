#ifndef AIS_LLAMA_BRIDGE_H
#define AIS_LLAMA_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void * AISLlamaEngineHandle;

AISLlamaEngineHandle AISLlamaEngineCreate(
  const char * model_path,
  int32_t context_size
);

void AISLlamaEngineDestroy(AISLlamaEngineHandle engine);

bool AISLlamaEngineBeginCompletion(
  AISLlamaEngineHandle engine,
  const char * prompt,
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

const char * AISLlamaBridgeLastError(void);

#ifdef __cplusplus
}
#endif

#endif
