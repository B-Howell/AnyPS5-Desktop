#include "retro_core_host_linux.h"

#include "retro_host_proxy.h"

#include <atomic>
#include <functional>
#include <map>
#include <mutex>
#include <optional>

namespace {
namespace ipc = anyps5::retro_ipc;
using ipc::ProxyFrame;
using ipc::ProxyResult;
using ipc::RetroHostProxy;

struct TextureState {
  std::mutex mutex;
  std::function<std::optional<ProxyFrame>()> acquire;
  std::optional<ProxyFrame> lease;
};

struct RetroTexture {
  FlPixelBufferTexture parent_instance;
  TextureState* state;
};

struct RetroTextureClass {
  FlPixelBufferTextureClass parent_class;
};

G_DEFINE_TYPE(RetroTexture, retro_texture, fl_pixel_buffer_texture_get_type())

static gboolean CopyPixels(FlPixelBufferTexture* texture, const uint8_t** pixels, uint32_t* width,
                           uint32_t* height, GError**) {
  auto* state = reinterpret_cast<RetroTexture*>(texture)->state;
  std::lock_guard<std::mutex> lock(state->mutex);
  state->lease = state->acquire ? state->acquire() : std::nullopt;
  if (!state->lease) {
    // Flutter may paint the texture before the first frame or after release.
    static constexpr uint8_t black[] = {0, 0, 0, 255};
    *pixels = black;
    *width = *height = 1;
    return TRUE;
  }
  *pixels = state->lease->pixels;
  *width = static_cast<uint32_t>(state->lease->width);
  *height = static_cast<uint32_t>(state->lease->height);
  return TRUE;
}

static void FinalizeTexture(GObject* object) {
  delete reinterpret_cast<RetroTexture*>(object)->state;
  G_OBJECT_CLASS(retro_texture_parent_class)->finalize(object);
}

static void retro_texture_class_init(RetroTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = CopyPixels;
  G_OBJECT_CLASS(klass)->finalize = FinalizeTexture;
}

static void retro_texture_init(RetroTexture* texture) { texture->state = new TextureState(); }

ipc::Value ToHost(FlValue* value) {
  if (!value) return ipc::Value();
  switch (fl_value_get_type(value)) {
    case FL_VALUE_TYPE_NULL: return ipc::Value();
    case FL_VALUE_TYPE_BOOL: return ipc::Value(static_cast<bool>(fl_value_get_bool(value)));
    case FL_VALUE_TYPE_INT: {
      const int64_t number = fl_value_get_int(value);
      if (number >= INT32_MIN && number <= INT32_MAX) return ipc::Value(static_cast<int32_t>(number));
      return ipc::Value(number);
    }
    case FL_VALUE_TYPE_FLOAT: return ipc::Value(fl_value_get_float(value));
    case FL_VALUE_TYPE_STRING: return ipc::Value(std::string(fl_value_get_string(value)));
    case FL_VALUE_TYPE_UINT8_LIST: {
      const auto* data = fl_value_get_uint8_list(value);
      return ipc::Value(ipc::Bytes(data, data + fl_value_get_length(value)));
    }
    case FL_VALUE_TYPE_INT32_LIST: {
      const auto* data = fl_value_get_int32_list(value);
      return ipc::Value(std::vector<int32_t>(data, data + fl_value_get_length(value)));
    }
    case FL_VALUE_TYPE_INT64_LIST: {
      const auto* data = fl_value_get_int64_list(value);
      return ipc::Value(std::vector<int64_t>(data, data + fl_value_get_length(value)));
    }
    case FL_VALUE_TYPE_FLOAT32_LIST: {
      const auto* data = fl_value_get_float32_list(value);
      return ipc::Value(std::vector<float>(data, data + fl_value_get_length(value)));
    }
    case FL_VALUE_TYPE_FLOAT_LIST: {
      const auto* data = fl_value_get_float_list(value);
      return ipc::Value(std::vector<double>(data, data + fl_value_get_length(value)));
    }
    case FL_VALUE_TYPE_LIST: {
      ipc::List out;
      for (size_t i = 0; i < fl_value_get_length(value); ++i) out.push_back(ToHost(fl_value_get_list_value(value, i)));
      return ipc::Value(std::move(out));
    }
    case FL_VALUE_TYPE_MAP: {
      ipc::Map out;
      for (size_t i = 0; i < fl_value_get_length(value); ++i)
        out.emplace(ToHost(fl_value_get_map_key(value, i)), ToHost(fl_value_get_map_value(value, i)));
      return ipc::Value(std::move(out));
    }
    default: return ipc::Value();
  }
}

FlValue* ToFlutter(const ipc::Value& value) {
  if (value.IsNull()) return fl_value_new_null();
  if (const auto* flag = std::get_if<bool>(&value)) return fl_value_new_bool(*flag);
  if (std::holds_alternative<int32_t>(value) || std::holds_alternative<int64_t>(value))
    return fl_value_new_int(value.LongValue());
  if (const auto* number = std::get_if<double>(&value)) return fl_value_new_float(*number);
  if (const auto* text = std::get_if<std::string>(&value)) return fl_value_new_string_sized(text->data(), text->size());
  if (const auto* bytes = std::get_if<ipc::Bytes>(&value)) return fl_value_new_uint8_list(bytes->data(), bytes->size());
  if (const auto* ints = std::get_if<std::vector<int32_t>>(&value)) return fl_value_new_int32_list(ints->data(), ints->size());
  if (const auto* longs = std::get_if<std::vector<int64_t>>(&value)) return fl_value_new_int64_list(longs->data(), longs->size());
  if (const auto* floats = std::get_if<std::vector<float>>(&value)) return fl_value_new_float32_list(floats->data(), floats->size());
  if (const auto* doubles = std::get_if<std::vector<double>>(&value)) return fl_value_new_float_list(doubles->data(), doubles->size());
  if (const auto* list = std::get_if<ipc::List>(&value)) {
    auto* out = fl_value_new_list();
    for (const auto& item : *list) fl_value_append_take(out, ToFlutter(item));
    return out;
  }
  auto* out = fl_value_new_map();
  for (const auto& [key, item] : std::get<ipc::Map>(value)) fl_value_set_take(out, ToFlutter(key), ToFlutter(item));
  return out;
}

gboolean RunTask(gpointer data) {
  (*static_cast<std::function<void()>*>(data))();
  return G_SOURCE_REMOVE;
}

void DeleteTask(gpointer data) { delete static_cast<std::function<void()>*>(data); }
}  // namespace

class RetroCoreHostLinux::Impl {
 public:
  explicit Impl(FlPluginRegistrar* registrar)
      : registrar_(FL_TEXTURE_REGISTRAR(g_object_ref(fl_plugin_registrar_get_texture_registrar(registrar)))),
        platform_context_(g_main_context_ref_thread_default()) {
    ipc::ProxyOptions options;
    options.host = RetroHostProxy::DefaultHostPath();
    options.texture_per_session = false;
    proxy_ = std::make_unique<RetroHostProxy>(
        std::move(options),
        ipc::ProxyPlatform{[this] { return Register(); }, [this](int64_t texture) { Unregister(texture); },
                           [this](int64_t) { ScheduleFrame(); },
                           [this](std::function<void()> task) { Post(std::move(task)); }});
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    channel_ = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar), "anyps5/retro_core",
                                     FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(channel_, OnCall, this, nullptr);
  }

  ~Impl() {
    Shutdown();
    *alive_ = false;
    g_clear_object(&channel_);
    g_clear_object(&registrar_);
    g_main_context_unref(platform_context_);
  }

  void Shutdown() {
    if (shutting_down_) return;
    shutting_down_ = true;
    fl_method_channel_set_method_call_handler(channel_, nullptr, nullptr, nullptr);
    proxy_->Shutdown();
  }

 private:
  static void OnCall(FlMethodChannel*, FlMethodCall* call, gpointer context) {
    auto* self = static_cast<Impl*>(context);
    g_object_ref(call);
    self->proxy_->Handle(fl_method_call_get_name(call), ToHost(fl_method_call_get_args(call)),
                         [call](ProxyResult answer) {
                           switch (answer.kind) {
                             case ProxyResult::Kind::kSuccess: {
                               g_autoptr(FlValue) result = ToFlutter(answer.value);
                               fl_method_call_respond_success(call, result, nullptr);
                               break;
                             }
                             case ProxyResult::Kind::kError:
                               fl_method_call_respond_error(call, answer.code.c_str(), answer.message.c_str(), nullptr,
                                                            nullptr);
                               break;
                             case ProxyResult::Kind::kNotImplemented:
                               fl_method_call_respond_not_implemented(call, nullptr);
                               break;
                           }
                           g_object_unref(call);
                         });
  }

  void Post(std::function<void()> task) {
    // Attaching a source, unlike invoke, cannot run the task inline on the
    // calling thread.
    GSource* source = g_idle_source_new();
    auto guarded = [alive = alive_, task = std::move(task)] {
      if (*alive) task();
    };
    g_source_set_callback(source, RunTask, new std::function<void()>(std::move(guarded)), DeleteTask);
    g_source_attach(source, platform_context_);
    g_source_unref(source);
  }

  void ScheduleFrame() {
    if (frame_pending_.exchange(true)) return;
    Post([this] {
      frame_pending_ = false;
      if (texture_) fl_texture_registrar_mark_texture_frame_available(registrar_, FL_TEXTURE(texture_));
    });
  }

  int64_t Register() {
    if (!texture_) texture_ = static_cast<RetroTexture*>(g_object_new(retro_texture_get_type(), nullptr));
    if (!fl_texture_registrar_register_texture(registrar_, FL_TEXTURE(texture_))) {
      g_clear_object(&texture_);
      return -1;
    }
    const auto id = fl_texture_get_id(FL_TEXTURE(texture_));
    std::lock_guard<std::mutex> lock(texture_->state->mutex);
    texture_->state->acquire = [this, id] { return proxy_->Acquire(id); };
    return id;
  }

  void Unregister(int64_t) {
    if (!texture_) return;
    {
      std::lock_guard<std::mutex> lock(texture_->state->mutex);
      texture_->state->acquire = nullptr;
      texture_->state->lease.reset();
    }
    fl_texture_registrar_unregister_texture(registrar_, FL_TEXTURE(texture_));
    g_clear_object(&texture_);
  }

  FlTextureRegistrar* registrar_;
  GMainContext* platform_context_;
  FlMethodChannel* channel_ = nullptr;
  std::unique_ptr<RetroHostProxy> proxy_;
  RetroTexture* texture_ = nullptr;
  std::atomic<bool> frame_pending_{false};
  std::shared_ptr<std::atomic<bool>> alive_ = std::make_shared<std::atomic<bool>>(true);
  bool shutting_down_ = false;
};

RetroCoreHostLinux::RetroCoreHostLinux(FlPluginRegistrar* registrar) : impl_(std::make_unique<Impl>(registrar)) {}
RetroCoreHostLinux::~RetroCoreHostLinux() = default;
void RetroCoreHostLinux::Shutdown() { impl_->Shutdown(); }
