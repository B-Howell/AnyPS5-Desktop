#include "retro_core_host.h"

#include "retro_host_proxy.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <map>
#include <mutex>

namespace {
using anyps5::retro_ipc::ProxyFrame;
using anyps5::retro_ipc::ProxyResult;
using anyps5::retro_ipc::RetroHostProxy;
namespace ipc = anyps5::retro_ipc;

constexpr UINT kRunTask = WM_APP + 0x52;
constexpr wchar_t kTaskWindowClass[] = L"AnyPS5RetroHostTasks";

ipc::Value ToHost(const flutter::EncodableValue& value) {
  if (std::holds_alternative<std::monostate>(value)) return ipc::Value();
  if (const auto* flag = std::get_if<bool>(&value)) return ipc::Value(*flag);
  if (const auto* narrow = std::get_if<int32_t>(&value)) return ipc::Value(*narrow);
  if (const auto* wide = std::get_if<int64_t>(&value)) return ipc::Value(*wide);
  if (const auto* number = std::get_if<double>(&value)) return ipc::Value(*number);
  if (const auto* text = std::get_if<std::string>(&value)) return ipc::Value(*text);
  if (const auto* bytes = std::get_if<std::vector<uint8_t>>(&value)) return ipc::Value(*bytes);
  if (const auto* ints = std::get_if<std::vector<int32_t>>(&value)) return ipc::Value(*ints);
  if (const auto* longs = std::get_if<std::vector<int64_t>>(&value)) return ipc::Value(*longs);
  if (const auto* doubles = std::get_if<std::vector<double>>(&value)) return ipc::Value(*doubles);
  if (const auto* floats = std::get_if<std::vector<float>>(&value)) return ipc::Value(*floats);
  if (const auto* list = std::get_if<flutter::EncodableList>(&value)) {
    ipc::List out;
    out.reserve(list->size());
    for (const auto& item : *list) out.push_back(ToHost(item));
    return ipc::Value(std::move(out));
  }
  if (const auto* map = std::get_if<flutter::EncodableMap>(&value)) {
    ipc::Map out;
    for (const auto& [key, item] : *map) out.emplace(ToHost(key), ToHost(item));
    return ipc::Value(std::move(out));
  }
  return ipc::Value();
}

flutter::EncodableValue ToFlutter(const ipc::Value& value) {
  if (value.IsNull()) return flutter::EncodableValue();
  if (const auto* flag = std::get_if<bool>(&value)) return flutter::EncodableValue(*flag);
  if (const auto* narrow = std::get_if<int32_t>(&value)) return flutter::EncodableValue(*narrow);
  if (const auto* wide = std::get_if<int64_t>(&value)) return flutter::EncodableValue(*wide);
  if (const auto* number = std::get_if<double>(&value)) return flutter::EncodableValue(*number);
  if (const auto* text = std::get_if<std::string>(&value)) return flutter::EncodableValue(*text);
  if (const auto* bytes = std::get_if<std::vector<uint8_t>>(&value)) return flutter::EncodableValue(*bytes);
  if (const auto* ints = std::get_if<std::vector<int32_t>>(&value)) return flutter::EncodableValue(*ints);
  if (const auto* longs = std::get_if<std::vector<int64_t>>(&value)) return flutter::EncodableValue(*longs);
  if (const auto* doubles = std::get_if<std::vector<double>>(&value)) return flutter::EncodableValue(*doubles);
  if (const auto* floats = std::get_if<std::vector<float>>(&value)) return flutter::EncodableValue(*floats);
  if (const auto* list = std::get_if<ipc::List>(&value)) {
    flutter::EncodableList out;
    out.reserve(list->size());
    for (const auto& item : *list) out.push_back(ToFlutter(item));
    return flutter::EncodableValue(std::move(out));
  }
  flutter::EncodableMap out;
  for (const auto& [key, item] : std::get<ipc::Map>(value)) out.emplace(ToFlutter(key), ToFlutter(item));
  return flutter::EncodableValue(std::move(out));
}

LRESULT CALLBACK TaskWindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kRunTask) {
    std::unique_ptr<std::function<void()>> task(reinterpret_cast<std::function<void()>*>(lparam));
    (*task)();
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

struct FrameLease {
  ProxyFrame frame;
  FlutterDesktopPixelBuffer buffer;
};
}  // namespace

class RetroCoreHost::Impl {
 public:
  Impl(flutter::BinaryMessenger* messenger, flutter::TextureRegistrar* textures)
      : textures_(textures),
        channel_(messenger, "anyps5/retro_core", &flutter::StandardMethodCodec::GetInstance()) {
    WNDCLASSW type{};
    type.lpfnWndProc = TaskWindowProc;
    type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = kTaskWindowClass;
    RegisterClassW(&type);
    tasks_ = CreateWindowExW(0, kTaskWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, type.hInstance, nullptr);
    anyps5::retro_ipc::ProxyOptions options;
    options.host = RetroHostProxy::DefaultHostPath();
    options.texture_per_session = true;
    proxy_ = std::make_unique<RetroHostProxy>(
        std::move(options),
        anyps5::retro_ipc::ProxyPlatform{
            [this] { return Register(); },
            [this](int64_t texture) { Unregister(texture); },
            [this](int64_t texture) { textures_->MarkTextureFrameAvailable(texture); },
            [window = tasks_](std::function<void()> task) {
              auto* owned = new std::function<void()>(std::move(task));
              if (!PostMessageW(window, kRunTask, 0, reinterpret_cast<LPARAM>(owned))) delete owned;
            }});
    channel_.SetMethodCallHandler([this](const auto& call, auto result) {
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply(std::move(result));
      proxy_->Handle(call.method_name(), call.arguments() ? ToHost(*call.arguments()) : ipc::Value(),
                     [reply](ProxyResult answer) {
                       switch (answer.kind) {
                         case ProxyResult::Kind::kSuccess:
                           reply->Success(ToFlutter(answer.value));
                           break;
                         case ProxyResult::Kind::kError:
                           reply->Error(answer.code, answer.message);
                           break;
                         case ProxyResult::Kind::kNotImplemented:
                           reply->NotImplemented();
                           break;
                       }
                     });
    });
  }

  ~Impl() {
    channel_.SetMethodCallHandler(nullptr);
    proxy_->Shutdown();
    proxy_.reset();
    if (tasks_) DestroyWindow(tasks_);
  }

 private:
  int64_t Register() {
    auto texture = std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(
        [this, slot = next_slot_++](size_t, size_t) -> const FlutterDesktopPixelBuffer* { return Copy(slot); }));
    const auto slot = next_slot_ - 1;
    const auto id = textures_->RegisterTexture(texture.get());
    if (id < 0) return -1;
    std::lock_guard<std::mutex> lock(mutex_);
    slots_[slot] = id;
    owned_[id] = {slot, std::move(texture)};
    return id;
  }

  void Unregister(int64_t id) {
    std::shared_ptr<flutter::TextureVariant> texture;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      const auto found = owned_.find(id);
      if (found == owned_.end()) return;
      slots_.erase(found->second.first);
      texture = std::move(found->second.second);
      owned_.erase(found);
    }
    textures_->UnregisterTexture(id, [texture] {});
  }

  const FlutterDesktopPixelBuffer* Copy(int64_t slot) {
    int64_t id;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      const auto found = slots_.find(slot);
      if (found == slots_.end()) return nullptr;
      id = found->second;
    }
    auto frame = proxy_ ? proxy_->Acquire(id) : std::nullopt;
    if (!frame) return nullptr;
    auto* lease = new FrameLease{std::move(*frame), {}};
    lease->buffer = {lease->frame.pixels, lease->frame.width, lease->frame.height,
                     [](void* data) { delete static_cast<FrameLease*>(data); }, lease};
    return &lease->buffer;
  }

  flutter::TextureRegistrar* textures_;
  flutter::MethodChannel<flutter::EncodableValue> channel_;
  HWND tasks_ = nullptr;
  std::unique_ptr<RetroHostProxy> proxy_;
  std::mutex mutex_;
  int64_t next_slot_ = 0;
  std::map<int64_t, int64_t> slots_;
  std::map<int64_t, std::pair<int64_t, std::shared_ptr<flutter::TextureVariant>>> owned_;
};

RetroCoreHost::RetroCoreHost(flutter::BinaryMessenger* messenger, flutter::TextureRegistrar* textures)
    : impl_(std::make_unique<Impl>(messenger, textures)) {}

RetroCoreHost::~RetroCoreHost() = default;
