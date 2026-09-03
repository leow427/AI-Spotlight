#include "AISLlamaBridge.h"

#include <llama/llama.h>

#include <algorithm>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

struct Engine {
  llama_model * model = nullptr;
  llama_context * context = nullptr;
  const llama_vocab * vocabulary = nullptr;
  llama_sampler * sampler = nullptr;
  int32_t generated_token_count = 0;
  int32_t maximum_token_count = 0;
};

thread_local std::string last_error;

void initialize_backend() {
  static std::once_flag once;
  std::call_once(once, [] {
    llama_backend_init();
  });
}

void set_error(const std::string & message) {
  last_error = message;
}

std::string format_prompt(Engine * engine, const char * prompt) {
  const char * chat_template = llama_model_chat_template(engine->model, nullptr);
  if (chat_template == nullptr) {
    return std::string(prompt);
  }

  llama_chat_message message = {"user", prompt};
  const int32_t required_size = llama_chat_apply_template(
    chat_template,
    &message,
    1,
    true,
    nullptr,
    0
  );
  if (required_size <= 0) {
    return std::string(prompt);
  }

  std::vector<char> formatted(static_cast<size_t>(required_size) + 1, '\0');
  const int32_t written = llama_chat_apply_template(
    chat_template,
    &message,
    1,
    true,
    formatted.data(),
    static_cast<int32_t>(formatted.size())
  );
  if (written <= 0) {
    return std::string(prompt);
  }

  return std::string(formatted.data(), static_cast<size_t>(written));
}

void replace_sampler(Engine * engine, float temperature) {
  if (engine->sampler != nullptr) {
    llama_sampler_free(engine->sampler);
  }

  const auto parameters = llama_sampler_chain_default_params();
  engine->sampler = llama_sampler_chain_init(parameters);
  if (temperature <= 0.0F) {
    llama_sampler_chain_add(engine->sampler, llama_sampler_init_greedy());
    return;
  }

  llama_sampler_chain_add(engine->sampler, llama_sampler_init_top_k(40));
  llama_sampler_chain_add(engine->sampler, llama_sampler_init_top_p(0.95F, 1));
  llama_sampler_chain_add(engine->sampler, llama_sampler_init_temp(temperature));
  llama_sampler_chain_add(engine->sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
}

} // namespace

AISLlamaEngineHandle AISLlamaEngineCreate(
  const char * model_path,
  int32_t context_size
) {
  if (model_path == nullptr || model_path[0] == '\0') {
    set_error("The local model path is empty.");
    return nullptr;
  }
  if (context_size < 256) {
    set_error("The local model context must be at least 256 tokens.");
    return nullptr;
  }

  initialize_backend();

  auto * engine = new Engine();
  auto model_parameters = llama_model_default_params();
  model_parameters.n_gpu_layers = 99;
  engine->model = llama_model_load_from_file(model_path, model_parameters);
  if (engine->model == nullptr) {
    set_error("llama.cpp could not load the selected GGUF model.");
    delete engine;
    return nullptr;
  }

  auto context_parameters = llama_context_default_params();
  context_parameters.n_ctx = static_cast<uint32_t>(context_size);
  context_parameters.n_batch = std::min<uint32_t>(512, context_parameters.n_ctx);
  const unsigned int hardware_threads = std::max(1U, std::thread::hardware_concurrency());
  const int32_t thread_count = static_cast<int32_t>(std::max(1U, std::min(8U, hardware_threads - 1U)));
  context_parameters.n_threads = thread_count;
  context_parameters.n_threads_batch = thread_count;
  engine->context = llama_init_from_model(engine->model, context_parameters);
  if (engine->context == nullptr) {
    set_error("llama.cpp could not create an inference context.");
    llama_model_free(engine->model);
    delete engine;
    return nullptr;
  }

  engine->vocabulary = llama_model_get_vocab(engine->model);
  return static_cast<AISLlamaEngineHandle>(engine);
}

void AISLlamaEngineDestroy(AISLlamaEngineHandle engine_handle) {
  auto * engine = static_cast<Engine *>(engine_handle);
  if (engine == nullptr) {
    return;
  }

  if (engine->sampler != nullptr) {
    llama_sampler_free(engine->sampler);
  }
  if (engine->context != nullptr) {
    llama_free(engine->context);
  }
  if (engine->model != nullptr) {
    llama_model_free(engine->model);
  }
  delete engine;
}

bool AISLlamaEngineBeginCompletion(
  AISLlamaEngineHandle engine_handle,
  const char * prompt,
  int32_t maximum_token_count,
  float temperature
) {
  auto * engine = static_cast<Engine *>(engine_handle);
  if (engine == nullptr || prompt == nullptr) {
    set_error("The local inference request is invalid.");
    return false;
  }

  const std::string formatted_prompt = format_prompt(engine, prompt);
  const int32_t required_token_count = -llama_tokenize(
    engine->vocabulary,
    formatted_prompt.c_str(),
    static_cast<int32_t>(formatted_prompt.size()),
    nullptr,
    0,
    true,
    true
  );
  if (required_token_count <= 0) {
    set_error("llama.cpp could not tokenize the prompt.");
    return false;
  }

  const int32_t context_size = static_cast<int32_t>(llama_n_ctx(engine->context));
  if (required_token_count >= context_size) {
    set_error("The prompt is too long for the installed local model context.");
    return false;
  }

  std::vector<llama_token> tokens(static_cast<size_t>(required_token_count));
  const int32_t token_count = llama_tokenize(
    engine->vocabulary,
    formatted_prompt.c_str(),
    static_cast<int32_t>(formatted_prompt.size()),
    tokens.data(),
    required_token_count,
    true,
    true
  );
  if (token_count < 0) {
    set_error("llama.cpp could not tokenize the prompt.");
    return false;
  }

  llama_kv_self_clear(engine->context);
  replace_sampler(engine, temperature);

  constexpr int32_t batch_size = 512;
  for (int32_t offset = 0; offset < token_count; offset += batch_size) {
    const int32_t current_batch_size = std::min(batch_size, token_count - offset);
    llama_batch prompt_batch = llama_batch_get_one(
      tokens.data() + offset,
      current_batch_size
    );
    const int32_t decode_result = llama_decode(engine->context, prompt_batch);
    if (decode_result != 0) {
      set_error("llama.cpp could not evaluate the prompt.");
      return false;
    }
  }

  engine->generated_token_count = 0;
  engine->maximum_token_count = std::max(
    1,
    std::min(maximum_token_count, context_size - token_count)
  );
  return true;
}

int32_t AISLlamaEngineNextToken(
  AISLlamaEngineHandle engine_handle,
  uint8_t * token_bytes,
  int32_t token_capacity,
  int32_t * token_byte_count
) {
  auto * engine = static_cast<Engine *>(engine_handle);
  if (engine == nullptr || engine->sampler == nullptr || token_byte_count == nullptr) {
    set_error("Local inference has not been prepared.");
    return -1;
  }
  if (engine->generated_token_count >= engine->maximum_token_count) {
    *token_byte_count = 0;
    return 0;
  }

  const llama_token token = llama_sampler_sample(engine->sampler, engine->context, -1);
  if (llama_vocab_is_eog(engine->vocabulary, token)) {
    *token_byte_count = 0;
    return 0;
  }

  int32_t piece_size = llama_token_to_piece(
    engine->vocabulary,
    token,
    nullptr,
    0,
    0,
    true
  );
  if (piece_size < 0) {
    piece_size = -piece_size;
  }
  if (piece_size > token_capacity || (piece_size > 0 && token_bytes == nullptr)) {
    set_error("A generated token exceeded the bridge buffer capacity.");
    return -1;
  }

  std::vector<char> piece(static_cast<size_t>(piece_size));
  const int32_t written = llama_token_to_piece(
    engine->vocabulary,
    token,
    piece.data(),
    piece_size,
    0,
    true
  );
  if (written < 0) {
    set_error("llama.cpp could not decode a generated token.");
    return -1;
  }

  llama_token mutable_token = token;
  llama_batch token_batch = llama_batch_get_one(&mutable_token, 1);
  const int32_t decode_result = llama_decode(engine->context, token_batch);
  if (decode_result != 0) {
    set_error("llama.cpp could not continue local inference.");
    return -1;
  }

  if (written > 0) {
    std::memcpy(token_bytes, piece.data(), static_cast<size_t>(written));
  }
  *token_byte_count = written;
  engine->generated_token_count += 1;
  return 1;
}

const char * AISLlamaBridgeLastError(void) {
  return last_error.c_str();
}
