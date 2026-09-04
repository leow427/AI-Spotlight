#include "AISLlamaBridge.h"

#include <llama/llama.h>

#include <algorithm>
#include <cstring>
#include <mutex>
#include <limits>
#include <string>
#include <thread>
#include <vector>

namespace {

struct Engine {
  llama_model * model = nullptr;
  llama_context * context = nullptr;
  const llama_vocab * vocabulary = nullptr;
  llama_sampler * sampler = nullptr;
  int32_t context_limit = 0;
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

bool format_prompt(
  const char * chat_template,
  const AISLlamaChatMessage * messages,
  int32_t message_count,
  std::string & result
) {
  if (chat_template == nullptr || chat_template[0] == '\0') {
    set_error("This model has no chat template. Choose a GGUF instruct/chat model with a supported template.");
    return false;
  }
  if (messages == nullptr || message_count <= 0) {
    set_error("The local conversation is empty.");
    return false;
  }
  std::vector<llama_chat_message> chat;
  for (int32_t index = 0; index < message_count; ++index) {
    const auto & message = messages[index];
    const char * expected_role = index % 2 == 0 ? "user" : "assistant";
    if (message.role == nullptr || message.content == nullptr ||
        std::strcmp(message.role, expected_role) != 0) {
      set_error("The local conversation must contain ordered user/assistant turns.");
      return false;
    }
    chat.push_back({message.role, message.content});
  }
  if (message_count % 2 == 0) {
    set_error("The local conversation must end with the current user message.");
    return false;
  }
  const int32_t required_size = llama_chat_apply_template(
    chat_template, chat.data(), chat.size(), true, nullptr, 0
  );
  if (required_size <= 0 || required_size == std::numeric_limits<int32_t>::max()) {
    set_error("llama.cpp cannot apply this model's chat template. Choose a model with a supported template.");
    return false;
  }
  std::vector<char> formatted(static_cast<size_t>(required_size) + 1, '\0');
  const int32_t written = llama_chat_apply_template(
    chat_template, chat.data(), chat.size(), true, formatted.data(), required_size + 1
  );
  if (written <= 0 || written > required_size) {
    set_error("llama.cpp could not format the conversation.");
    return false;
  }
  result.assign(formatted.data(), static_cast<size_t>(written));
  return true;
}

int32_t count_tokens(Engine * engine, const std::string & prompt) {
  const int32_t count = -llama_tokenize(
    engine->vocabulary, prompt.c_str(), static_cast<int32_t>(prompt.size()),
    nullptr, 0, true, true
  );
  if (count <= 0) {
    set_error("llama.cpp could not tokenize the conversation.");
    return -1;
  }
  return count;
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
  const int32_t training_context = llama_model_n_ctx_train(engine->model);
  if (training_context <= 0) {
    set_error("The model does not declare a usable context size.");
    llama_model_free(engine->model);
    delete engine;
    return nullptr;
  }
  engine->context_limit = std::min(context_size, training_context);
  context_parameters.n_ctx = static_cast<uint32_t>(engine->context_limit);
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

  engine->context_limit = std::min(engine->context_limit, static_cast<int32_t>(llama_n_ctx(engine->context)));
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

int32_t AISLlamaFormatChat(
  const char * chat_template,
  const AISLlamaChatMessage * messages,
  int32_t message_count,
  char * buffer,
  int32_t buffer_capacity
) {
  std::string formatted;
  if (!format_prompt(chat_template, messages, message_count, formatted)) { return -1; }
  const auto size = static_cast<int32_t>(formatted.size());
  if (buffer != nullptr && buffer_capacity > size) {
    std::memcpy(buffer, formatted.c_str(), formatted.size() + 1);
  }
  return size;
}

int32_t AISLlamaEngineContextSize(AISLlamaEngineHandle engine_handle) {
  const auto * engine = static_cast<Engine *>(engine_handle);
  return engine == nullptr ? 0 : engine->context_limit;
}

int32_t AISLlamaEngineCountChatTokens(
  AISLlamaEngineHandle engine_handle,
  const AISLlamaChatMessage * messages,
  int32_t message_count
) {
  auto * engine = static_cast<Engine *>(engine_handle);
  if (engine == nullptr) {
    set_error("The local engine is not loaded.");
    return -1;
  }
  std::string formatted;
  if (!format_prompt(llama_model_chat_template(engine->model, nullptr), messages, message_count, formatted)) {
    return -1;
  }
  return count_tokens(engine, formatted);
}

bool AISLlamaEngineBeginCompletion(
  AISLlamaEngineHandle engine_handle,
  const AISLlamaChatMessage * messages,
  int32_t message_count,
  int32_t maximum_token_count,
  float temperature
) {
  auto * engine = static_cast<Engine *>(engine_handle);
  if (engine == nullptr || maximum_token_count <= 0) {
    set_error("The local inference request is invalid.");
    return false;
  }

  std::string formatted_prompt;
  if (!format_prompt(llama_model_chat_template(engine->model, nullptr), messages, message_count, formatted_prompt)) {
    return false;
  }
  const int32_t required_token_count = count_tokens(engine, formatted_prompt);
  if (required_token_count <= 0) { return false; }

  const int32_t context_size = engine->context_limit;
  // Keep one extra slot and the entire requested output allowance. Never silently
  // shrink output to squeeze in an oversized input.
  if (static_cast<int64_t>(required_token_count) + maximum_token_count + 1 > context_size) {
    set_error("This conversation exceeds the local model context after reserving reply space. Shorten the message or choose a model with a larger context.");
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

  const int32_t batch_size = static_cast<int32_t>(llama_n_batch(engine->context));
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
  engine->maximum_token_count = maximum_token_count;
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
