#include "retro_core_host.h"
#include "ps1_netplay_timeline.h"
#include "retro_vulkan_video.h"

#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <mmsystem.h>
#include <wrl/client.h>

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <optional>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;

// Layouts and command values from the libretro v1 C ABI.
struct GameInfo {
  const char* path;
  const void* data;
  size_t size;
  const char* meta;
};
struct Variable {
  const char* key;
  const char* value;
};
struct ExtendedMessage {
  const char* text;
  unsigned duration, priority;
  int level, target, type;
  int8_t progress;
};
struct CoreOptionValue {
  const char* value;
  const char* label;
};
struct CoreOptionDefinition {
  const char* key;
  const char* title;
  const char* category_title;
  const char* description;
  const char* category_description;
  const char* category;
  CoreOptionValue values[128];
  const char* default_value;
};
struct CoreOptionsV2 {
  const void* categories;
  const CoreOptionDefinition* definitions;
};
struct CoreOptionsV2Intl {
  const CoreOptionsV2* english;
  const CoreOptionsV2* localized;
};
struct Geometry {
  unsigned width, height, max_width, max_height;
  float aspect;
};
struct AvInfo {
  Geometry geometry;
  double fps, sample_rate;
};
struct HardwareCallbacks {
  int context_type;
  void (*reset)();
  uintptr_t (*framebuffer)();
  void (*(*proc_address)(const char*))();
  bool depth, stencil, bottom_left_origin;
  unsigned version_major, version_minor;
  bool cache_context;
  void (*destroy)();
  bool debug_context;
};
struct D3D11Interface {
  int type = 3;
  unsigned version = 1;
  void* handle = nullptr;
  ID3D11Device* device = nullptr;
  ID3D11DeviceContext* context = nullptr;
  D3D_FEATURE_LEVEL feature_level{};
  decltype(&D3DCompile) compile = D3DCompile;
};
constexpr int kD3D11 = 7;
constexpr char kPs3Resolution[] = "rpcs3_resolution_scale";
constexpr unsigned kMaxFrameSize = 4096;
constexpr size_t kMaxPs1Checkpoint = 12 * 1024 * 1024;
constexpr uint32_t kPs1CatchupHistory = 1024;
constexpr uint32_t kPs1CatchupBatch = 120;
using Ps1DiscHash = std::array<uint8_t, 32>;
using CheckpointBytes = std::vector<uint8_t>;
using Ps1Ports = std::array<ps1_netplay::PadInput, 2>;
enum EnvironmentCommand {
  kCanDupe = 3, kShutdown = 7, kSystemDirectory = 9, kPixelFormat = 10,
  kInputDescriptors = 11, kGetVariable = 15, kSetVariables = 16,
  kVariableUpdate = 17, kSupportNoGame = 18, kCorePath = 19,
  kContentDirectory = 30, kSaveDirectory = 31, kSetAv = 32,
  kSetGeometry = 37, kAudioVideoEnable = 47, kFastForward = 49,
  kCoreOptionsVersion = 52, kSetHardware = 14, kHardwareInterface = 41 | 0x10000,
  kHardwareNegotiation = 43 | 0x10000,
  kPreferredHardware = 56, kSetCoreOptionsV2 = 67, kSetCoreOptionsV2Intl = 68,
  kMessageVersion = 59, kExtendedMessage = 60,
  kFrontendCompileProgress = 0x20000 | 0x4150,
  kGetInputBitmasks = 51 | 0x10000,
};

constexpr std::pair<std::string_view, std::string_view> kPs1NetplayOptions[] = {
    {"swanstation_GPU_Renderer", "Software"},
    {"swanstation_GPU_ResolutionScale", "1"},
    {"swanstation_CPU_ExecutionMode", "CachedInterpreter"},
    {"swanstation_CPU_RecompilerBlockLinking", "false"},
    {"swanstation_GPU_UseThread", "false"},
    {"swanstation_BIOS_PatchFastBoot", "false"},
};

class Ps1MatchStorage {
 public:
  explicit Ps1MatchStorage(const std::string& bios) {
    const auto input = std::filesystem::u8path(bios);
    if (!input.is_absolute() || !std::filesystem::is_regular_file(input) ||
        std::filesystem::file_size(input) != 512 * 1024)
      throw std::runtime_error("PS1 netplay requires a verified SCPH1001 BIOS.");
    const auto temp = std::filesystem::canonical(std::filesystem::temp_directory_path());
    std::random_device random;
    for (int attempt = 0; attempt < 8; ++attempt) {
      const auto candidate = temp / ("anyps5-ps1-netplay-" + std::to_string(random()) + "-" +
                                     std::to_string(random()));
      if (!std::filesystem::create_directory(candidate)) continue;
      root_ = candidate;
      break;
    }
    if (root_.empty()) throw std::runtime_error("Could not create PS1 netplay scratch storage.");
    try {
      std::filesystem::create_directory(root_ / "system");
      std::filesystem::create_directory(root_ / "save");
      std::filesystem::copy_file(input, root_ / "system" / "scph1001.bin");
    } catch (...) {
      Cleanup();
      throw;
    }
  }
  ~Ps1MatchStorage() { Cleanup(); }
  Ps1MatchStorage(const Ps1MatchStorage&) = delete;
  Ps1MatchStorage& operator=(const Ps1MatchStorage&) = delete;

  std::string system() const { return (root_ / "system").u8string(); }
  std::string saves() const { return (root_ / "save").u8string(); }
  std::string content() const { return root_.u8string(); }

 private:
  void Cleanup() noexcept {
    if (root_.empty()) return;
    std::error_code error;
    const auto resolved = std::filesystem::canonical(root_, error);
    if (!error && resolved == root_) std::filesystem::remove_all(root_, error);
  }

  std::filesystem::path root_;
};

std::optional<int64_t> IntegerValue(const Value& value) {
  if (const auto* narrow = std::get_if<int32_t>(&value)) return *narrow;
  if (const auto* wide = std::get_if<int64_t>(&value)) return *wide;
  return std::nullopt;
}

Value FrameValue(const std::optional<uint32_t>& frame) {
  return frame ? Value(static_cast<int64_t>(*frame)) : Value();
}

std::string NetplayFingerprint(const uint8_t* memory, size_t size) {
  uint64_t hash = 14695981039346656037ULL;
  for (size_t index = 0; index < size; ++index)
    hash = (hash ^ memory[index]) * 1099511628211ULL;
  std::string result(16, '0');
  constexpr char digits[] = "0123456789abcdef";
  for (size_t index = result.size(); index > 0; --index) {
    result[index - 1] = digits[hash & 15];
    hash >>= 4;
  }
  return result;
}

struct Frame {
  std::vector<uint8_t> pixels;
  size_t width = 0;
  size_t height = 0;
};
struct FrameLease {
  std::shared_ptr<Frame> frame;
  FlutterDesktopPixelBuffer buffer;
};

class HardwareVideo {
 public:
  bool Open() {
    // LRPS2 selects Shader Model 5.1 at feature level 11.1, which its D3D11 renderer cannot use.
    constexpr D3D_FEATURE_LEVEL levels[]{D3D_FEATURE_LEVEL_11_0};
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, ARRAYSIZE(levels),
                                 D3D11_SDK_VERSION, &device_, &render_interface.feature_level,
                                 &context_))) return false;
    render_interface.handle = this;
    render_interface.device = device_.Get();
    render_interface.context = context_.Get();
    return true;
  }

  std::shared_ptr<Frame> Read(unsigned width, unsigned height) {
    Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> view;
    context_->PSGetShaderResources(0, 1, &view);
    if (!view) return nullptr;
    Microsoft::WRL::ComPtr<ID3D11Resource> resource;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> source;
    view->GetResource(&resource);
    if (FAILED(resource.As(&source))) return nullptr;
    D3D11_TEXTURE2D_DESC desc{};
    source->GetDesc(&desc);
    const auto format = desc.Format;
    const bool bgra = format == DXGI_FORMAT_B8G8R8A8_UNORM ||
                      format == DXGI_FORMAT_B8G8R8X8_UNORM;
    if ((!bgra && format != DXGI_FORMAT_R8G8B8A8_UNORM) || desc.SampleDesc.Count != 1 ||
        width > desc.Width || height > desc.Height) return nullptr;
    if (!staging_ || width != width_ || height != height_ || format != format_) {
      D3D11_TEXTURE2D_DESC staging{width, height, 1, 1, format, {1, 0},
                                  D3D11_USAGE_STAGING, 0, D3D11_CPU_ACCESS_READ, 0};
      if (FAILED(device_->CreateTexture2D(&staging, nullptr, staging_.ReleaseAndGetAddressOf())))
        return nullptr;
      width_ = width;
      height_ = height;
      format_ = format;
    }
    auto frame = std::make_shared<Frame>();
    frame->width = width;
    frame->height = height;
    frame->pixels.resize(static_cast<size_t>(width) * height * 4);
    const D3D11_BOX box{0, 0, 0, width, height, 1};
    context_->CopySubresourceRegion(staging_.Get(), 0, 0, 0, 0, source.Get(), 0, &box);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(context_->Map(staging_.Get(), 0, D3D11_MAP_READ, 0, &mapped))) return nullptr;
    const auto* input = static_cast<const uint8_t*>(mapped.pData);
    for (unsigned row = 0; row < height; ++row) {
      const auto* source_row = input + static_cast<size_t>(row) * mapped.RowPitch;
      auto* output = frame->pixels.data() + static_cast<size_t>(row) * width * 4;
      for (unsigned column = 0; column < width; ++column, output += 4, source_row += 4) {
        output[0] = source_row[bgra ? 2 : 0];
        output[1] = source_row[1];
        output[2] = source_row[bgra ? 0 : 2];
        output[3] = 255;
      }
    }
    context_->Unmap(staging_.Get(), 0);
    return frame;
  }

  D3D11Interface render_interface;

  void Clear() {
    if (!context_) return;
    staging_.Reset();
    context_->ClearState();
    context_->Flush();
  }

 private:
  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> staging_;
  unsigned width_ = 0, height_ = 0;
  DXGI_FORMAT format_ = DXGI_FORMAT_UNKNOWN;
};

class StereoOutput {
 public:
  ~StereoOutput() { Close(); }

  bool Open(double rate) {
    std::lock_guard<std::mutex> lock(mutex_);
    CloseLocked();
    if (!std::isfinite(rate) || rate < 8000 || rate > 192000) return false;
    const DWORD sample_rate = static_cast<DWORD>(std::lround(rate));
    WAVEFORMATEX format{WAVE_FORMAT_PCM, 2, sample_rate, sample_rate * 4, 4, 16, 0};
    return waveOutOpen(&device_, WAVE_MAPPER, &format, 0, 0, CALLBACK_NULL) == MMSYSERR_NOERROR;
  }

  void Flush() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (device_) waveOutReset(device_);
    pending_count_ = 0;
  }

  void Write(const int16_t* stereo, size_t frames) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!device_) return;
    while (frames > 0) {
      const size_t count = std::min(frames, pending_.size() / 2 - pending_count_);
      std::copy_n(stereo, count * 2, pending_.data() + pending_count_ * 2);
      pending_count_ += count;
      stereo += count * 2;
      frames -= count;
      if (pending_count_ == pending_.size() / 2) Submit();
    }
  }

  int64_t dropped_frames() const { return dropped_frames_; }

  void Close() {
    std::lock_guard<std::mutex> lock(mutex_);
    CloseLocked();
  }

 private:
  struct Slot {
    std::array<int16_t, 1024> samples{};
    WAVEHDR header{};
  };

  void Submit() {
    pending_count_ = 0;
    for (auto& slot : slots_) {
      if ((slot.header.dwFlags & WHDR_INQUEUE) != 0) continue;
      if ((slot.header.dwFlags & WHDR_PREPARED) != 0) {
        if (waveOutUnprepareHeader(device_, &slot.header, sizeof(WAVEHDR)) != MMSYSERR_NOERROR) continue;
      }
      slot.samples = pending_;
      slot.header = {};
      slot.header.lpData = reinterpret_cast<char*>(slot.samples.data());
      slot.header.dwBufferLength = static_cast<DWORD>(sizeof(slot.samples));
      if (waveOutPrepareHeader(device_, &slot.header, sizeof(WAVEHDR)) == MMSYSERR_NOERROR &&
          waveOutWrite(device_, &slot.header, sizeof(WAVEHDR)) == MMSYSERR_NOERROR) {
        return;
      }
      break;
    }
    dropped_frames_ += pending_.size() / 2;
  }

  void CloseLocked() {
    if (device_) {
      waveOutReset(device_);
      for (auto& slot : slots_) {
        if ((slot.header.dwFlags & WHDR_PREPARED) != 0) {
          waveOutUnprepareHeader(device_, &slot.header, sizeof(WAVEHDR));
        }
        slot.header = {};
      }
      waveOutClose(device_);
      device_ = nullptr;
    }
    pending_count_ = 0;
  }

  std::mutex mutex_;
  HWAVEOUT device_ = nullptr;
  std::array<Slot, 8> slots_{};
  std::array<int16_t, 1024> pending_{};
  size_t pending_count_ = 0;
  std::atomic<int64_t> dropped_frames_{0};
};

template <typename T>
T Symbol(HMODULE dll, const char* name) {
  auto address = GetProcAddress(dll, name);
  if (!address) throw std::runtime_error(std::string("Core is missing ") + name);
  T function;
  static_assert(sizeof(function) == sizeof(address));
  std::memcpy(&function, &address, sizeof(function));
  return function;
}

const std::string* StringField(const Map& map, const char* name) {
  const auto found = map.find(Value(name));
  return found == map.end() ? nullptr : std::get_if<std::string>(&found->second);
}

bool ResolutionOption(const std::string& key) {
  return key == "swanstation_GPU_ResolutionScale" || key == "pcsx2_upscale_multiplier";
}

constexpr auto kPs1Resolution = "swanstation_GPU_ResolutionScale";
constexpr auto kPs1Filter = "swanstation_GPU_TextureFilter";
constexpr auto kPs2Resolution = "pcsx2_upscale_multiplier";
constexpr auto kPs2Anisotropy = "pcsx2_anisotropic_filtering";
constexpr auto kPs2Trilinear = "pcsx2_trilinear_filtering";

bool Ps1GraphicsOption(const std::string& key) {
  return key == kPs1Resolution || key == kPs1Filter;
}

bool TrialOption(const std::string& key) {
  return Ps1GraphicsOption(key) || key == kPs2Resolution || key == kPs2Anisotropy || key == kPs2Trilinear ||
         key == kPs3Resolution || key == "rpcs3_anisotropic_filter";
}

bool LiveCoreOption(const std::string& key, bool hardware) {
  return key == "swanstation_Display_CropMode" || key == "pcsx2_deinterlace_mode" ||
         (hardware && (ResolutionOption(key) || TrialOption(key)));
}

bool BootCoreOption(const std::string& key) {
  static constexpr std::string_view keys[] = {
      "swanstation_GPU_Renderer", "swanstation_CPU_ExecutionMode",
      "swanstation_CDROM_PreCacheCHD", "swanstation_CDROM_ReadThread",
      "swanstation_CDROM_ReadaheadSectors", "pcsx2_renderer", "pcsx2_mtvu",
      "pcsx2_fastcdvd", "pcsx2_sw_renderer_threads", "pcsx2_disable_shader_cache",
      "rpcs3_ppu_decoder", "rpcs3_spu_decoder", "rpcs3_preferred_spu_threads",
      "rpcs3_llvm_threads", "rpcs3_shader_compiler_threads", "rpcs3_llvm_precompilation",
      "rpcs3_emulate_hdd_speed", "rpcs3_emulate_bdvd_speed", "rpcs3_disk_cache_size",
      "rpcs3_spu_cache", "rpcs3_master_volume", "rpcs3_language", "rpcs3_license_area",
      "rpcs3_enter_button",
  };
  return std::find(std::begin(keys), std::end(keys), key) != std::end(keys);
}

bool SupportedBootValue(const std::string& key, std::string_view value, bool hardware_available) {
  if (key == "swanstation_GPU_Renderer") {
    return value == "Software" || (hardware_available && value == "D3D11");
  }
  if (key == "pcsx2_renderer") {
    return value == "Software (SW)" || value == "Software (HW)" ||
           (hardware_available && value == "D3D11");
  }
  return key != "rpcs3_disk_cache_size" || value != "wipe";
}

void RestoreCard(const std::filesystem::path& path, void* data, size_t size) {
  if (!data || !size || !std::filesystem::exists(path)) return;
  if (std::filesystem::file_size(path) != size) {
    throw std::runtime_error("The PlayStation memory card has an unexpected size");
  }
  std::ifstream file(path, std::ios::binary);
  if (!file.read(static_cast<char*>(data), static_cast<std::streamsize>(size))) {
    throw std::runtime_error("Could not read the PlayStation memory card");
  }
}

void StoreCard(const std::filesystem::path& path, const void* data, size_t size) {
  if (!data || !size) return;
  auto temporary = path;
  temporary += L".tmp";
  std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
  file.write(static_cast<const char*>(data), static_cast<std::streamsize>(size));
  file.close();
  if (!file || !MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    throw std::runtime_error("Could not write the PlayStation memory card");
  }
}
}  // namespace

class RetroCoreSession {
 public:
  RetroCoreSession(flutter::TextureRegistrar* registrar, std::string core,
                   std::string disc, std::string system, std::string saves,
                   std::string initial_resolution = {},
                   std::map<std::string, std::string> initial_graphics = {},
                   std::optional<unsigned> netplay_seat = std::nullopt,
                   const std::string& netplay_bios = {}, bool local_staging = false)
      : registrar_(registrar), core_(std::move(core)), disc_(std::move(disc)),
        netplay_(netplay_seat ? std::make_unique<ps1_netplay::Timeline>(*netplay_seat) : nullptr),
        match_storage_(netplay_ ? std::make_unique<Ps1MatchStorage>(netplay_bios) : nullptr),
        system_(match_storage_ ? match_storage_->system() : std::move(system)),
        saves_(match_storage_ ? match_storage_->saves() : std::move(saves)),
        content_(match_storage_ ? match_storage_->content()
                                : std::filesystem::u8path(disc_).parent_path().u8string()),
        initial_resolution_(std::move(initial_resolution)),
        initial_graphics_(std::move(initial_graphics)),
        ps3_(std::filesystem::u8path(core_).filename() == L"rpcs3_libretro.dll"),
        local_staging_(local_staging),
        texture_(flutter::PixelBufferTexture([this](size_t, size_t) { return CopyFrame(); })) {
    if (local_staging_ && netplay_seat != 0u)
      throw std::invalid_argument("Only the PS1 host can start in local play.");
  }

  ~RetroCoreSession() { Stop(); Join(); }

  bool Start() {
    texture_id_ = registrar_->RegisterTexture(&texture_);
    if (texture_id_ < 0) return false;
    worker_ = std::thread([this] { Run(); });
    return true;
  }

  int64_t texture_id() const { return texture_id_; }
  bool ended() const { return ended_; }
  void Stop() { stop_ = true; }
  void Join() { if (worker_.joinable()) worker_.join(); }

  void Pause(bool pause) {
    if (netplay_) {
      if (pause) SetInput(0, {});
      return;
    }
    if (paused_.exchange(pause) == pause) return;
    if (pause) {
      SetInput(0, {});
      audio_.Flush();
      std::lock_guard<std::mutex> lock(telemetry_mutex_);
      last_frame_at_ = {};
    }
  }

  void SetInput(uint16_t buttons, const std::array<int16_t, 4>& axes) {
    std::lock_guard<std::mutex> lock(input_mutex_);
    buttons_ = buttons;
    axes_ = axes;
  }

  bool StartNetplay() {
    if (!netplay_ || !netplay_ready_ || stop_ || ended_) return false;
    std::scoped_lock lock(netplay_mutex_, checkpoint_mutex_);
    if (checkpoint_ || (StagingLocal() && !netplay_held_)) return false;
    if (netplay_held_) {
      netplay_->Reset();
      checkpoint_history_.clear();
      netplay_fingerprints_.clear();
      netplay_held_ = false;
      netplay_epoch_reset_ = true;
    }
    netplay_->Start();
    netplay_started_ = true;
    return true;
  }

  std::optional<uint32_t> HoldNetplay() {
    if (!CheckpointReady()) return std::nullopt;
    std::scoped_lock lock(netplay_mutex_, checkpoint_mutex_);
    if (checkpoint_) return std::nullopt;
    if (StagingLocal()) {
      if (local_prepared_) return std::nullopt;
      netplay_held_ = true;
      return local_frame_;
    }
    if (!netplay_started_ || !netplay_->Hold()) return std::nullopt;
    netplay_held_ = true;
    return netplay_->frame();
  }

  bool ResumeLocalNetplay() {
    if (!CheckpointReady()) return false;
    std::scoped_lock lock(netplay_mutex_, checkpoint_mutex_);
    if (!local_staging_ || !netplay_held_ || checkpoint_) return false;
    if (netplay_started_) {
      netplay_started_ = false;
      local_frame_ = 0;
      checkpoint_history_.clear();
    }
    netplay_held_ = false;
    return true;
  }

  std::optional<int64_t> RequestCheckpoint(const Ps1DiscHash& digest, CheckpointBytes restore = {},
                                           std::optional<uint32_t> frame = std::nullopt) {
    if (!CheckpointReady() || restore.size() > kMaxPs1Checkpoint ||
        frame.has_value() != !restore.empty() || (frame && *frame > ps1_netplay::Timeline::kMaxFrame))
      return std::nullopt;
    std::scoped_lock lock(netplay_mutex_, checkpoint_mutex_);
    if (checkpoint_ || (frame && (netplay_started_ || StagingLocal())) || (!frame && replay_cursor_))
      return std::nullopt;
    return QueueCheckpoint(digest, std::move(restore), frame, {});
  }

  std::optional<int64_t> RequestCatchup(uint32_t first, std::vector<Ps1Ports> frames) {
    if (!CheckpointReady() || frames.empty() || frames.size() > kPs1CatchupBatch ||
        first > ps1_netplay::Timeline::kMaxFrame - frames.size())
      return std::nullopt;
    std::scoped_lock lock(netplay_mutex_, checkpoint_mutex_);
    if (checkpoint_ || netplay_started_ || replay_cursor_ != first) return std::nullopt;
    return QueueCheckpoint({}, {}, first, std::move(frames));
  }

  std::optional<Map> CheckpointHistory(uint32_t first) {
    if (!CheckpointReady()) return std::nullopt;
    std::lock_guard<std::mutex> lock(netplay_mutex_);
    const auto next = StagingLocal() ? local_frame_ : netplay_->frame();
    const auto oldest = next - static_cast<uint32_t>(checkpoint_history_.size());
    if ((!netplay_started_ && !StagingLocal()) || first < oldest || first > next) return std::nullopt;
    List frames;
    const auto count = std::min(next - first, kPs1CatchupBatch);
    for (uint32_t frame = first; frame < first + count; ++frame) {
      List ports;
      for (const auto& pad : checkpoint_history_[frame - oldest]) {
        List values{Value(static_cast<int32_t>(pad.buttons))};
        for (const auto axis : pad.axes) values.emplace_back(static_cast<int32_t>(axis));
        ports.emplace_back(std::move(values));
      }
      frames.emplace_back(std::move(ports));
    }
    return Map{{Value("nextFrame"), Value(static_cast<int64_t>(next))},
               {Value("frames"), Value(std::move(frames))}};
  }

  Value TakeCheckpoint(int64_t id) {
    std::lock_guard<std::mutex> lock(checkpoint_mutex_);
    if (!checkpoint_ || checkpoint_->id != id || stop_ || ended_) return Value(false);
    if (!checkpoint_->result) return Value();
    auto result = std::move(*checkpoint_->result);
    checkpoint_.reset();
    return result;
  }

  void CancelCheckpoint(int64_t id) {
    std::lock_guard<std::mutex> lock(checkpoint_mutex_);
    if (!checkpoint_ || checkpoint_->id != id) return;
    if (checkpoint_->frame && checkpoint_->running) stop_ = true;
    if (checkpoint_->running && !checkpoint_->result) {
      checkpoint_->cancelled = true;
    } else {
      checkpoint_.reset();
    }
  }


  std::optional<Map> SyncNetplay(const std::vector<ps1_netplay::FrameInput>& remote,
                                const std::optional<uint32_t>& acknowledged) {
    if (!netplay_ || stop_ || ended_) return std::nullopt;
    std::lock_guard<std::mutex> lock(netplay_mutex_);
    if (StagingLocal() || !netplay_->Receive(remote, acknowledged)) return std::nullopt;
    List local;
    for (const auto& sample : netplay_->LocalPacket()) {
      List input{Value(static_cast<int64_t>(sample.frame)), Value(static_cast<int32_t>(sample.input.buttons))};
      for (const auto axis : sample.input.axes) input.emplace_back(static_cast<int32_t>(axis));
      local.emplace_back(std::move(input));
    }
    List fingerprints;
    for (const auto& [frame, hash] : netplay_fingerprints_)
      fingerprints.emplace_back(List{Value(static_cast<int64_t>(frame)), Value(hash)});
    return Map{
        {Value("local"), Value(std::move(local))},
        {Value("frame"), Value(static_cast<int64_t>(netplay_->frame()))},
        {Value("confirmedFrame"), FrameValue(netplay_->confirmed())},
        {Value("receivedFrame"), FrameValue(netplay_->received())},
        {Value("waiting"), Value(netplay_->waiting())},
        {Value("fingerprints"), Value(std::move(fingerprints))},
    };
  }

  Map Status() {
    std::lock_guard<std::mutex> lock(settings_mutex_);
    const bool show_progress = std::chrono::steady_clock::now() < progress_until_;
    Map options;
    for (const auto& entry : options_) {
      if (!entry.second.graphics && !entry.second.boot &&
          !LiveCoreOption(entry.first, hardware_frame_)) continue;
      List values;
      for (const auto& value : entry.second.values) values.emplace_back(value);
      const auto selected = entry.second.pending.value_or(entry.second.selected);
      List labels;
      for (const auto& label : entry.second.labels) labels.emplace_back(label);
      options.emplace(Value(entry.first), Value(Map{
          {Value("values"), Value(std::move(values))},
          {Value("labels"), Value(std::move(labels))},
          {Value("title"), Value(entry.second.title)},
          {Value("restart"), Value(entry.second.boot || (entry.second.graphics && !TrialOption(entry.first)))},
          {Value("selected"), Value(static_cast<int32_t>(selected))},
          {Value("activeValue"), Value(entry.second.values[entry.second.selected])},
      }));
    }
    Map status{
        {Value("ready"), Value(frame_ready_.load())},
        {Value("presented"), Value(presented_.load())},
        {Value("ended"), Value(ended_.load())},
        {Value("error"), Value(error_)},
        {Value("aspect"), Value(static_cast<double>(aspect_.load()))},
        {Value("hardware"), Value(hardware_frame_.load())},
        {Value("frameWidth"), Value(static_cast<int32_t>(frame_width_.load()))},
        {Value("frameHeight"), Value(static_cast<int32_t>(frame_height_.load()))},
        {Value("resolutionError"), Value(resolution_error_)},
        {Value("graphicsPending"), Value(graphics_queued_ || graphics_applying_)},
        {Value("progressLabel"), show_progress ? Value(progress_label_) : Value()},
        {Value("progressPercent"), show_progress && progress_percent_ >= 0 ? Value(progress_percent_) : Value()},
        {Value("options"), Value(std::move(options))},
        {Value("tuningTelemetry"), Value(TuningTelemetry())},
    };
    if (netplay_) status.emplace(Value("netplayReady"), Value(netplay_ready_.load()));
    if (netplay_) status.emplace(Value("portableCheckpoint"), Value(checkpoint_supported_.load()));
    return status;
  }

  bool SetOption(const std::string& key, const std::string& value) {
    if (netplay_) return false;
    std::lock_guard<std::mutex> lock(settings_mutex_);
    const auto option = options_.find(key);
    if (option == options_.end() ||
        (!option->second.graphics && !option->second.boot && !LiveCoreOption(key, hardware_frame_))) return false;
    auto& data = option->second;
    const auto choice = std::find(data.values.begin(), data.values.end(), value);
    if (choice == data.values.end()) return false;
    const auto selected = static_cast<size_t>(choice - data.values.begin());
    if (graphics_applying_ || (graphics_queued_ && (key == kPs2Anisotropy || key == kPs2Trilinear))) return false;
    if (Ps1GraphicsOption(key) || key == kPs2Resolution) {
      data.pending = selected;
      graphics_queued_ = true;
      resolution_error_.clear();
    } else if (data.boot || (data.graphics && !TrialOption(key))) {
      data.pending = selected;
    } else if (selected != data.selected) {
      data.selected = selected;
      options_changed_ = true;
    }
    return true;
  }

  bool SetTuningOptions(const Map& expected, const Map& values) {
    if (netplay_ || !presented_ || !hardware_frame_ || values.empty() || expected.size() != values.size())
      return false;
    std::lock_guard<std::mutex> lock(settings_mutex_);
    if (graphics_applying_ || graphics_queued_) return false;
    std::vector<std::pair<Option*, size_t>> changes;
    bool checkpoint = false;
    for (const auto& entry : values) {
      const auto* key = std::get_if<std::string>(&entry.first);
      const auto* value = std::get_if<std::string>(&entry.second);
      if (!key || !value || !TrialOption(*key)) return false;
      checkpoint |= Ps1GraphicsOption(*key) || *key == kPs2Resolution;
      const auto* current = StringField(expected, key->c_str());
      const auto option = options_.find(*key);
      if (!current || option == options_.end()) return false;
      auto& data = option->second;
      if (data.values[data.selected] != *current) return false;
      const auto choice = std::find(data.values.begin(), data.values.end(), *value);
      if (choice == data.values.end()) return false;
      changes.emplace_back(&data, static_cast<size_t>(choice - data.values.begin()));
    }
    for (const auto& change : changes) {
      if (checkpoint) change.first->pending = change.second;
      else change.first->selected = change.second;
    }
    if (checkpoint) {
      graphics_queued_ = true;
      resolution_error_.clear();
    } else {
      options_changed_ = true;
    }
    return true;
  }

 private:
  struct Option {
    std::vector<std::string> values;
    std::vector<std::string> labels;
    std::string title;
    bool graphics = false;
    bool boot = false;
    size_t selected = 0;
    std::optional<size_t> pending;
  };

  void SetCoreOptions(const CoreOptionsV2* options) {
    if (!ps3_ || !options || !options->definitions) return;
    std::lock_guard<std::mutex> lock(settings_mutex_);
    for (auto* row = options->definitions; row->key; ++row) {
      const std::string key = row->key;
      if (options_.count(key)) continue;
      Option option;
      if (row->title) option.title = row->title;
      option.graphics = row->category && std::strcmp(row->category, "gpu") == 0 &&
                        key != "rpcs3_renderer";
      option.boot = BootCoreOption(key);
      std::string preferred = row->default_value ? row->default_value : "";
      if (key == "rpcs3_renderer") preferred = "vulkan";
      if (option.graphics || option.boot) {
        const auto saved = initial_graphics_.find(key);
        if (saved != initial_graphics_.end()) preferred = saved->second;
      }
      for (const auto& value : row->values) {
        if (!value.value) break;
        if (!SupportedBootValue(key, value.value, hardware_available_)) continue;
        if (key == kPs3Resolution && std::atoi(value.value) > 200) continue;
        option.values.emplace_back(value.value);
        option.labels.emplace_back(value.label ? value.label : value.value);
      }
      auto choice = std::find(option.values.begin(), option.values.end(), preferred);
      if (choice == option.values.end() && row->default_value) {
        choice = std::find(option.values.begin(), option.values.end(), row->default_value);
      }
      if (choice != option.values.end()) option.selected = static_cast<size_t>(choice - option.values.begin());
      if (!option.values.empty()) options_.emplace(key, std::move(option));
    }
  }

  template <typename Reopen>
  void ApplyCheckpointGraphics(HMODULE dll, const Reopen& reopen, void (*step)(), bool ps1,
                               void*& card, size_t& card_size, const std::filesystem::path& card_path) {
    using Clock = std::chrono::steady_clock;
    struct Change { Option* option; size_t before; size_t after; };
    std::vector<Change> changes;
    {
      std::lock_guard<std::mutex> lock(settings_mutex_);
      if (!graphics_queued_) return;
      graphics_queued_ = false;
      constexpr std::array<const char*, 2> ps1_keys{kPs1Resolution, kPs1Filter};
      constexpr std::array<const char*, 3> ps2_keys{kPs2Resolution, kPs2Anisotropy, kPs2Trilinear};
      const auto* keys = ps1 ? ps1_keys.data() : ps2_keys.data();
      const auto count = ps1 ? ps1_keys.size() : ps2_keys.size();
      for (size_t index = 0; index < count; ++index) {
        const auto* key = keys[index];
        const auto found = options_.find(key);
        if (found == options_.end()) continue;
        auto& option = found->second;
        const auto pending = std::exchange(option.pending, std::nullopt);
        if (pending && *pending != option.selected)
          changes.push_back({&option, option.selected, *pending});
      }
      if (changes.empty()) return;
      graphics_applying_ = true;
    }
    const auto serialize_size = Symbol<size_t (*)()>(dll, "retro_serialize_size");
    const auto serialize = Symbol<bool (*)(void*, size_t)>(dll, "retro_serialize");
    const auto unserialize = Symbol<bool (*)(const void*, size_t)>(dll, "retro_unserialize");
    const auto size = serialize_size();
    std::vector<uint8_t> state(size);
    bool checkpoint_ready = size != 0 && serialize(state.data(), size);
    std::string failure = "The emulator could not apply those graphics settings.";
    if (checkpoint_ready && card) {
      try {
        StoreCard(card_path, card, card_size);
      } catch (const std::exception& error) {
        checkpoint_ready = false;
        failure = error.what();
      }
    }
    bool applied = false;
    if (checkpoint_ready) {
      const auto restore = [&](bool use_requested) {
        {
          std::lock_guard<std::mutex> lock(settings_mutex_);
          for (const auto& change : changes)
            change.option->selected = use_requested ? change.after : change.before;
          if (ps1) options_changed_ = true;
        }
        suppress_frame_ = true;
        if (ps1) step();
        const bool restored = (ps1 || reopen()) && unserialize(state.data(), size);
        suppress_frame_ = false;
        if (!restored) return false;
        const auto before = hardware_frames_;
        const auto deadline = Clock::now() + std::chrono::seconds(2);
        while (!stop_ && hardware_frames_ == before && Clock::now() < deadline) {
          step();
          if (hardware_frames_ == before)
            std::this_thread::sleep_for(std::chrono::milliseconds(4));
        }
        return stop_ || hardware_frames_ != before;
      };
      audio_.Flush();
      applied = restore(true);
      if (!applied && !restore(false))
        throw std::runtime_error("The emulator could not restore the game after changing graphics.");
      if (ps1) {
        card = Symbol<void* (*)(unsigned)>(dll, "retro_get_memory_data")(0);
        card_size = Symbol<size_t (*)(unsigned)>(dll, "retro_get_memory_size")(0);
      }
    }
    std::lock_guard<std::mutex> lock(settings_mutex_);
    graphics_applying_ = false;
    if (!applied) resolution_error_ = std::move(failure);
  }

  const FlutterDesktopPixelBuffer* CopyFrame() {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    if (!frame_) return nullptr;
    presented_ = true;
    auto* lease = new FrameLease{frame_, {}};
    lease->buffer = {lease->frame->pixels.data(), lease->frame->width, lease->frame->height,
                     [](void* data) { delete static_cast<FrameLease*>(data); }, lease};
    return &lease->buffer;
  }

  void Publish(const void* data, unsigned width, unsigned height, size_t pitch) {
    if (suppress_frame_ || !data || width == 0 || height == 0 || width > kMaxFrameSize || height > kMaxFrameSize)
      return;
    if (data == reinterpret_cast<const void*>(UINTPTR_MAX)) {
      if (hardware_callbacks_.context_type == kD3D11) {
        if (auto frame = hardware_.Read(width, height)) SubmitFrame(std::move(frame), true);
      } else if (hardware_callbacks_.context_type == kVulkan) {
        auto frame = std::make_shared<Frame>();
        frame->width = width;
        frame->height = height;
        frame->pixels.resize(static_cast<size_t>(width) * height * 4);
        if (vulkan_.Read(frame->pixels.data(), width, height)) {
          SubmitFrame(std::move(frame), true);
        } else {
          std::lock_guard<std::mutex> lock(settings_mutex_);
          error_ = "The PS3 Vulkan frame could not be read.";
          stop_ = true;
        }
      }
      return;
    }
    const int format = pixel_format_;
    const size_t bytes = format == 1 ? 4 : 2;
    if (pitch < width * bytes) return;
    auto frame = std::make_shared<Frame>();
    frame->width = width;
    frame->height = height;
    frame->pixels.resize(static_cast<size_t>(width) * height * 4);
    auto* output = frame->pixels.data();
    const auto* input = static_cast<const uint8_t*>(data);
    for (unsigned row = 0; row < height; ++row) {
      const auto* source = input + row * pitch;
      for (unsigned column = 0; column < width; ++column, source += bytes, output += 4) {
        if (format == 1) {
          output[0] = source[2];
          output[1] = source[1];
          output[2] = source[0];
        } else {
          const unsigned pixel = source[0] | (source[1] << 8);
          const unsigned red = (pixel >> (format == 2 ? 11 : 10)) & 31;
          const unsigned green = (pixel >> 5) & (format == 2 ? 63 : 31);
          const unsigned blue = pixel & 31;
          output[0] = static_cast<uint8_t>((red << 3) | (red >> 2));
          output[1] = static_cast<uint8_t>(format == 2 ? (green << 2) | (green >> 4)
                                                       : (green << 3) | (green >> 2));
          output[2] = static_cast<uint8_t>((blue << 3) | (blue >> 2));
        }
        output[3] = 255;
      }
    }
    SubmitFrame(std::move(frame), false);
  }

  Map TuningTelemetry() {
    using Clock = std::chrono::steady_clock;
    std::lock_guard<std::mutex> lock(telemetry_mutex_);
    List intervals;
    for (const auto count : frame_intervals_) intervals.emplace_back(count);
    return {
        {Value("clockMs"), Value(static_cast<int64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count()))},
        {Value("frames"), Value(video_frames_)},
        {Value("steps"), Value(steps_.load())},
        {Value("audioFrames"), Value(audio_frames_.load())},
        {Value("droppedAudioFrames"), Value(audio_.dropped_frames())},
        {Value("frameIntervals"), Value(std::move(intervals))},
        {Value("targetFps"), Value(target_fps_)},
        {Value("audioRate"), Value(audio_rate_)},
    };
  }

  void RecordFrame() {
    using Clock = std::chrono::steady_clock;
    const auto now = Clock::now();
    std::lock_guard<std::mutex> lock(telemetry_mutex_);
    ++video_frames_;
    if (last_frame_at_ != Clock::time_point{}) {
      const auto millis = std::chrono::duration<double, std::milli>(now - last_frame_at_).count();
      static constexpr std::array<int, 13> limits{8, 12, 16, 20, 25, 35, 50, 75, 100, 150, 250, 500, 1000};
      const auto index = std::min(static_cast<size_t>(std::lower_bound(limits.begin(), limits.end(), millis) -
                                                     limits.begin()), limits.size() - 1);
      ++frame_intervals_[index];
    }
    last_frame_at_ = now;
  }

  void SubmitFrame(std::shared_ptr<Frame> frame, bool hardware) {
    if (!paused_) RecordFrame();
    if (hardware) ++hardware_frames_;
    hardware_frame_ = hardware;
    frame_width_ = static_cast<unsigned>(frame->width);
    frame_height_ = static_cast<unsigned>(frame->height);
    {
      std::lock_guard<std::mutex> lock(frame_mutex_);
      frame_ = std::move(frame);
    }
    frame_ready_ = true;
    registrar_->MarkTextureFrameAvailable(texture_id_);
  }

  void SetAspect(float aspect) {
    if (std::isfinite(aspect) && aspect > 0.5f && aspect <= 4.f) aspect_ = aspect;
  }

  void SetVariables(const Variable* variables) {
    std::lock_guard<std::mutex> lock(settings_mutex_);
    for (; variables->key && variables->value; ++variables) {
      const std::string key = variables->key;
      const std::string declaration = variables->value;
      const auto delimiter = declaration.find("; ");
      if (delimiter == std::string::npos || options_.count(key)) continue;
      Option option;
      option.title = declaration.substr(0, delimiter);
      option.boot = BootCoreOption(key);
      std::istringstream list(declaration.substr(delimiter + 2));
      for (std::string value; std::getline(list, value, '|');) {
        if (!SupportedBootValue(key, value, hardware_available_)) continue;
        if (ResolutionOption(key) && !value.empty() && value[0] >= '0' && value[0] <= '9' &&
            std::stoi(value) > 4) continue;
        if (!netplay_) {
          if (key.find("renderer") != std::string::npos || key.find("Renderer") != std::string::npos) {
            if (value == "Software" || value == "Software (HW)") option.selected = option.values.size();
          } else if (key.find("FastBoot") != std::string::npos || key == "pcsx2_fastboot") {
            if (value == "enabled" || value == "true") option.selected = option.values.size();
          }
        }
        option.values.push_back(std::move(value));
      }
      if (hardware_available_ &&
          (key == "swanstation_GPU_Renderer" || key == "pcsx2_renderer")) {
        const auto hardware = std::find(option.values.begin(), option.values.end(), "D3D11");
        if (hardware != option.values.end())
          option.selected = static_cast<size_t>(hardware - option.values.begin());
      }
      if (hardware_available_ && ResolutionOption(key)) {
        const auto saved = std::find(option.values.begin(), option.values.end(), initial_resolution_);
        if (saved != option.values.end())
          option.selected = static_cast<size_t>(saved - option.values.begin());
      }
      if (!netplay_ && !ResolutionOption(key) && (option.boot || (hardware_available_ && TrialOption(key)))) {
        const auto saved = initial_graphics_.find(key);
        if (saved != initial_graphics_.end()) {
          const auto choice = std::find(option.values.begin(), option.values.end(), saved->second);
          if (choice != option.values.end())
            option.selected = static_cast<size_t>(choice - option.values.begin());
        }
      }
      if (netplay_) {
        for (const auto& [name, value] : kPs1NetplayOptions) {
          if (name != key) continue;
          const auto selected = std::find(option.values.begin(), option.values.end(), value);
          if (selected != option.values.end())
            option.selected = static_cast<size_t>(selected - option.values.begin());
          break;
        }
      }
      if (!option.values.empty()) options_.emplace(key, std::move(option));
    }
  }

  bool Environment(unsigned command, void* data) {
    if (command == kShutdown) {
      stop_ = true;
      return true;
    }
    if (command == kGetInputBitmasks) return netplay_ != nullptr;
    if (!data) return false;
    switch (command) {
      case kMessageVersion:
        *static_cast<unsigned*>(data) = 1;
        return true;
      case kFrontendCompileProgress:
        *static_cast<bool*>(data) = ps3_;
        return ps3_;
      case kExtendedMessage: {
        const auto& message = *static_cast<const ExtendedMessage*>(data);
        if (message.type != 3 || message.target == 2 || !message.text ||
            message.progress < -1 || message.progress > 100)
          return false;
        std::lock_guard<std::mutex> lock(settings_mutex_);
        progress_label_ = message.text;
        progress_percent_ = message.progress;
        progress_until_ = std::chrono::steady_clock::now() +
            std::chrono::milliseconds(std::min(message.duration, 5000u));
        return true;
      }
      case kSetHardware: {
        auto& callbacks = *static_cast<HardwareCallbacks*>(data);
        if (!hardware_available_ || callbacks.context_type != (ps3_ ? kVulkan : kD3D11))
          return false;
        callbacks.framebuffer = []() -> uintptr_t { return 0; };
        callbacks.proc_address = [](const char*) -> void (*)() { return nullptr; };
        hardware_callbacks_ = callbacks;
        return true;
      }
      case kHardwareNegotiation:
        return ps3_ && vulkan_.SetNegotiation(*static_cast<const RetroVulkanNegotiation*>(data));
      case kHardwareInterface:
        if (hardware_callbacks_.context_type == kVulkan) {
          *static_cast<const RetroVulkanInterface**>(data) = &vulkan_.render_interface();
          return true;
        }
        if (hardware_callbacks_.context_type == kD3D11) {
          *static_cast<const D3D11Interface**>(data) = &hardware_.render_interface;
          return true;
        }
        return false;
      case kPreferredHardware:
        if (!hardware_available_) return false;
        *static_cast<int*>(data) = ps3_ ? kVulkan : kD3D11;
        return true;
      case kCanDupe:
        *static_cast<bool*>(data) = true;
        return true;
      case kSystemDirectory:
        *static_cast<const char**>(data) = system_.c_str();
        return true;
      case kCorePath:
        *static_cast<const char**>(data) = core_.c_str();
        return true;
      case kContentDirectory:
        *static_cast<const char**>(data) = content_.c_str();
        return true;
      case kSaveDirectory:
        *static_cast<const char**>(data) = saves_.c_str();
        return true;
      case kPixelFormat: {
        const auto value = *static_cast<const int*>(data);
        if (value < 0 || value > 2) return false;
        pixel_format_ = value;
        return true;
      }
      case kGetVariable: {
        std::lock_guard<std::mutex> lock(settings_mutex_);
        auto& variable = *static_cast<Variable*>(data);
        const auto found = variable.key ? options_.find(variable.key) : options_.end();
        variable.value = found == options_.end() ? nullptr :
            found->second.values[found->second.selected].c_str();
        return true;
      }
      case kSetVariables:
        SetVariables(static_cast<const Variable*>(data));
        return true;
      case kVariableUpdate: {
        std::lock_guard<std::mutex> lock(settings_mutex_);
        *static_cast<bool*>(data) = std::exchange(options_changed_, false);
        return true;
      }
      case kInputDescriptors:
      case kSupportNoGame:
        return true;
      case kSetAv:
        SetAspect(static_cast<const AvInfo*>(data)->geometry.aspect);
        return true;
      case kSetGeometry:
        SetAspect(static_cast<const Geometry*>(data)->aspect);
        return true;
      case kFastForward:
        *static_cast<bool*>(data) = false;
        return true;
      case kAudioVideoEnable:
        *static_cast<unsigned*>(data) = 3;
        return true;
      case kCoreOptionsVersion:
        *static_cast<unsigned*>(data) = ps3_ ? 2u : 0u;
        return true;
      case kSetCoreOptionsV2:
        SetCoreOptions(static_cast<const CoreOptionsV2*>(data));
        return ps3_;
      case kSetCoreOptionsV2Intl:
        SetCoreOptions(static_cast<const CoreOptionsV2Intl*>(data)->english);
        return ps3_;
      default:
        return false;
    }
  }

  int16_t Input(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (netplay_) {
      if (port >= netplay_ports_.size()) return 0;
      const auto& input = netplay_ports_[port];
      if (device == 1 && id == 256) return static_cast<int16_t>(input.buttons);
      if (device == 1 && id < 16) return (input.buttons & (1u << id)) != 0;
      if (device == 5 && index < 2 && id < 2) return input.axes[index * 2 + id];
      return 0;
    }
    if (suppress_frame_ || port != 0 || paused_) return 0;
    std::lock_guard<std::mutex> lock(input_mutex_);
    if (device == 1 && id < 16) return (buttons_ & (1u << id)) != 0;
    if (device == 5 && index < 2 && id < 2) return axes_[index * 2 + id];
    return 0;
  }

  void ValidateNetplay(const uint8_t* memory, size_t memory_size) {
    if (!memory || memory_size != 2 * 1024 * 1024)
      throw std::runtime_error("PS1 netplay could not access the core's main RAM.");
    {
      std::lock_guard<std::mutex> lock(settings_mutex_);
      for (const auto& [name, value] : kPs1NetplayOptions) {
        const auto option = options_.find(std::string(name));
        if (option == options_.end() || option->second.values[option->second.selected] != value)
          throw std::runtime_error("The PS1 core could not configure the required netplay profile.");
      }
    }
  }

  struct CheckpointJob {
    int64_t id;
    Ps1DiscHash digest;
    CheckpointBytes restore;
    std::optional<uint32_t> frame;
    std::vector<Ps1Ports> replay;
    bool running = false;
    std::optional<Value> result;
    bool cancelled = false;
  };

  using SavePortable = size_t (*)(void*, size_t, const uint8_t*);
  using LoadPortable = bool (*)(const void*, size_t, const uint8_t*);

  bool CheckpointReady() const { return checkpoint_supported_ && netplay_ready_ && !stop_ && !ended_; }

  // Caller holds netplay_mutex_.
  bool StagingLocal() const { return local_staging_ && !netplay_started_; }

  // Both callers hold checkpoint_mutex_ and netplay_mutex_.
  int64_t QueueCheckpoint(const Ps1DiscHash& digest, CheckpointBytes restore,
                          std::optional<uint32_t> frame, std::vector<Ps1Ports> replay) {
    static std::atomic<int64_t> next_id{0};
    const auto id = ++next_id;
    checkpoint_ = CheckpointJob{id, digest, std::move(restore), frame, std::move(replay), false, std::nullopt};
    return id;
  }

  void ServiceCheckpoint(SavePortable save, LoadPortable load, size_t capacity, void (*step)()) {
    std::optional<CheckpointJob> work;
    {
      std::lock_guard<std::mutex> lock(checkpoint_mutex_);
      if (!checkpoint_ || checkpoint_->running) return;
      work = std::move(*checkpoint_);
      // Keep the request identity and kind visible while the core call runs.
      checkpoint_->frame = work->frame;
      checkpoint_->running = true;
    }
    Value result(false);
    std::optional<uint32_t> cursor;
    if (!work->frame) {
      uint32_t frame;
      {
        std::lock_guard<std::mutex> lock(netplay_mutex_);
        frame = StagingLocal() ? local_frame_ : netplay_->frame();
      }
      CheckpointBytes bytes(capacity);
      const auto used = save(bytes.data(), bytes.size(), work->digest.data());
      if (used && used <= bytes.size()) {
        bytes.resize(used);
        result = Value(Map{{Value("frame"), Value(static_cast<int64_t>(frame))},
                           {Value("state"), Value(std::move(bytes))}});
      }
    } else if (!work->restore.empty()) {
      const bool imported = load(work->restore.data(), work->restore.size(), work->digest.data());
      if (imported) cursor = work->frame;
      result = Value(imported);
    } else {
      suppress_frame_ = true;
      for (const auto& ports : work->replay) {
        if (stop_) break;
        netplay_ports_ = ports;
        step();
      }
      suppress_frame_ = false;
      netplay_ports_ = {};
      if (!stop_) cursor = *work->frame + static_cast<uint32_t>(work->replay.size());
      result = Value(cursor.has_value());
    }
    std::lock_guard<std::mutex> lock(checkpoint_mutex_);
    if (checkpoint_->cancelled) {
      checkpoint_.reset();
    } else {
      if (cursor) replay_cursor_ = cursor;
      checkpoint_->result = std::move(result);
    }
  }

  void RunNetplay(HMODULE dll, void (*step)(), std::chrono::steady_clock::duration frame_time,
                  const uint8_t* memory, size_t memory_size) {
    using Clock = std::chrono::steady_clock;
    const auto save = reinterpret_cast<SavePortable>(GetProcAddress(dll, "retro_anyps5_export_checkpoint_v1"));
    const auto load = reinterpret_cast<LoadPortable>(GetProcAddress(dll, "retro_anyps5_import_checkpoint_v1"));
    const size_t maximum = save && load ? Symbol<size_t (*)()>(dll, "retro_serialize_size")() : 0;
    constexpr size_t prefix = 40;
    checkpoint_supported_ = maximum && maximum <= kMaxPs1Checkpoint - prefix;
    if (local_staging_ && !checkpoint_supported_)
      throw std::runtime_error("Local PS1 hosting requires the portable checkpoint core.");
    netplay_ready_ = true;
    auto next = Clock::now();
    auto last_advance = next;
    bool started_before = false;
    while (!stop_) {
      if (checkpoint_supported_) ServiceCheckpoint(save, load, maximum + prefix, step);
      ps1_netplay::PadInput local;
      {
        std::lock_guard<std::mutex> lock(input_mutex_);
        local = {buttons_, axes_};
      }
      bool started;
      bool staging;
      bool epoch_reset;
      bool advance;
      uint32_t frame;
      {
        std::lock_guard<std::mutex> lock(netplay_mutex_);
        started = netplay_started_ && !netplay_held_;
        staging = StagingLocal();
        epoch_reset = std::exchange(netplay_epoch_reset_, false);
        frame = staging ? local_frame_ : netplay_->frame();
        if (staging) {
          advance = !netplay_held_ && frame < ps1_netplay::Timeline::kMaxFrame;
          local_prepared_ = advance;
          if (advance) netplay_ports_ = {local, {}};
        } else {
          advance = netplay_->Prepare(local, netplay_ports_);
        }
      }
      if (started && (!started_before || epoch_reset)) {
        last_advance = Clock::now();
      }
      started_before = started;
      if (!advance) {
        // The invitation owner releases a staged host on timeout or disconnect.
        if (!local_staging_ &&
            Clock::now() - last_advance > (started ? std::chrono::seconds(15) : std::chrono::seconds(60)))
          throw std::runtime_error(started ? "PS1 netplay stopped waiting for the other player."
                                           : "PS1 netplay did not start in time.");
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        next = Clock::now();
        continue;
      }
      step();
      ++steps_;
      std::string fingerprint;
      if (!staging && (frame + 1) % 120 == 0) fingerprint = NetplayFingerprint(memory, memory_size);
      {
        std::lock_guard<std::mutex> lock(netplay_mutex_);
        if (staging) {
          ++local_frame_;
          local_prepared_ = false;
        } else {
          netplay_->Commit();
        }
        if (checkpoint_supported_) {
          if (checkpoint_history_.size() == kPs1CatchupHistory) checkpoint_history_.pop_front();
          checkpoint_history_.push_back(netplay_ports_);
        }
        if (!fingerprint.empty()) {
          if (netplay_fingerprints_.size() == 16) netplay_fingerprints_.erase(netplay_fingerprints_.begin());
          netplay_fingerprints_.emplace_back(frame, std::move(fingerprint));
        }
      }
      last_advance = Clock::now();
      next += frame_time;
      if (next < last_advance - frame_time) next = last_advance;
      std::this_thread::sleep_until(next);
    }
  }

  void Run() {
    using Clock = std::chrono::steady_clock;
    using VoidFunction = void (*)();
    HMODULE dll = nullptr;
    VoidFunction deinit = nullptr;
    VoidFunction unload = nullptr;
    bool initialized = false;
    bool loaded = false;
    active_ = this;
    try {
      hardware_available_ = !netplay_ && (ps3_ ? vulkan_.Load() : hardware_.Open());
      if (ps3_ && !hardware_available_)
        throw std::runtime_error("PS3 requires a working Vulkan driver.");
      const auto path = std::filesystem::u8path(core_);
      dll = LoadLibraryExW(path.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
      if (!dll) throw std::runtime_error("Could not load the configured emulator core");
      if (Symbol<unsigned (*)()>(dll, "retro_api_version")() != 1)
        throw std::runtime_error("Unsupported emulator core API");
      const auto init = Symbol<VoidFunction>(dll, "retro_init");
      deinit = Symbol<VoidFunction>(dll, "retro_deinit");
      unload = Symbol<VoidFunction>(dll, "retro_unload_game");
      const auto load = Symbol<bool (*)(const GameInfo*)>(dll, "retro_load_game");
      const auto step = Symbol<VoidFunction>(dll, "retro_run");
      const auto av_info = Symbol<void (*)(AvInfo*)>(dll, "retro_get_system_av_info");
      Symbol<void (*)(bool (*)(unsigned, void*))>(dll, "retro_set_environment")(
          [](unsigned command, void* data) { return active_.load()->Environment(command, data); });
      Symbol<void (*)(void (*)(const void*, unsigned, unsigned, size_t))>(dll, "retro_set_video_refresh")(
          [](const void* data, unsigned width, unsigned height, size_t pitch) {
            active_.load()->Publish(data, width, height, pitch);
          });
      Symbol<void (*)(void (*)(int16_t, int16_t))>(dll, "retro_set_audio_sample")(
          [](int16_t left, int16_t right) {
            auto* session = active_.load();
            const int16_t stereo[]{left, right};
            if (!session->paused_ && !session->suppress_frame_) {
              ++session->audio_frames_;
              session->audio_.Write(stereo, 1);
            }
          });
      Symbol<void (*)(size_t (*)(const int16_t*, size_t))>(dll, "retro_set_audio_sample_batch")(
          [](const int16_t* samples, size_t frames) {
            auto* session = active_.load();
            if (!session->paused_ && !session->suppress_frame_) {
              session->audio_frames_ += frames;
              session->audio_.Write(samples, frames);
            }
            return frames;
          });
      Symbol<void (*)(void (*)())>(dll, "retro_set_input_poll")([] {});
      Symbol<void (*)(int16_t (*)(unsigned, unsigned, unsigned, unsigned))>(dll, "retro_set_input_state")(
          [](unsigned port, unsigned device, unsigned index, unsigned id) {
            return active_.load()->Input(port, device, index, id);
          });
      const GameInfo game{disc_.c_str(), nullptr, 0, nullptr};
      const auto reopen = [&] {
        if (loaded) unload();
        if (initialized) deinit();
        loaded = false;
        hardware_.Clear();
        hardware_callbacks_ = {};
        init();
        initialized = true;
        if (ps3_ && hardware_callbacks_.context_type != kVulkan)
          throw std::runtime_error("The PS3 core did not request a Vulkan context.");
        if (ps3_) {
          const auto controller = Symbol<void (*)(unsigned, unsigned)>(dll, "retro_set_controller_port_device");
          controller(0, 1);
          for (unsigned port = 1; port < 7; ++port) controller(port, 0);
        }
        loaded = load(&game);
        if (loaded && netplay_) {
          const auto controller = Symbol<void (*)(unsigned, unsigned)>(dll, "retro_set_controller_port_device");
          for (unsigned port = 0; port < 2; ++port) controller(port, 1);
        }
        if (loaded && ps3_) {
          if (!vulkan_.Open()) throw std::runtime_error("The PS3 Vulkan device could not be initialized.");
        }
        if (loaded && hardware_callbacks_.reset) hardware_callbacks_.reset();
        return loaded;
      };
      const bool ps2 = path.filename() == L"pcsx2_libretro.dll";
      const bool ps1 = path.filename() == L"swanstation_libretro.dll";
      const auto use_native_resolution = [&] {
        std::lock_guard<std::mutex> lock(settings_mutex_);
        const auto scale = options_.find(ps2 ? "pcsx2_upscale_multiplier" : "swanstation_GPU_ResolutionScale");
        return scale != options_.end() && std::exchange(scale->second.selected, 0) != 0;
      };
      if (!reopen() && (!use_native_resolution() || !reopen()))
        throw std::runtime_error("The core could not boot this disc. Check its BIOS and game files.");
      void* card = nullptr;
      size_t card_size = 0;
      std::filesystem::path card_path;
      const auto restore_card = [&] {
        if (!ps1 || netplay_) return;
        card = Symbol<void* (*)(unsigned)>(dll, "retro_get_memory_data")(0);
        card_size = Symbol<size_t (*)(unsigned)>(dll, "retro_get_memory_size")(0);
        card_path = std::filesystem::u8path(saves_) / std::filesystem::u8path(disc_).stem();
        card_path += L".srm";
        RestoreCard(card_path, card, card_size);
      };
      restore_card();
      AvInfo av{};
      av_info(&av);
      SetAspect(av.geometry.aspect);
      const bool audio_open = audio_.Open(av.sample_rate);
      const double fps = std::isfinite(av.fps) && av.fps > 30 && av.fps <= 120 ? av.fps : 60.0;
      {
        std::lock_guard<std::mutex> lock(telemetry_mutex_);
        target_fps_ = fps;
        audio_rate_ = audio_open ? av.sample_rate : 0;
      }
      const auto frame_time = std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(1.0 / fps));
      if (netplay_) {
        const auto memory = static_cast<const uint8_t*>(
            Symbol<void* (*)(unsigned)>(dll, "retro_get_memory_data")(2));
        const auto size = Symbol<size_t (*)(unsigned)>(dll, "retro_get_memory_size")(2);
        ValidateNetplay(memory, size);
        RunNetplay(dll, step, frame_time, memory, size);
      }
      auto next = Clock::now();
      auto hardware_deadline = next + std::chrono::seconds(8);
      while (!netplay_ && !stop_) {
        if (ps1 || ps2)
          ApplyCheckpointGraphics(dll, reopen, step, ps1, card, card_size, card_path);
        if (!ps3_ && hardware_callbacks_.reset && !frame_ready_ && Clock::now() > hardware_deadline) {
          if (!use_native_resolution()) {
            std::lock_guard<std::mutex> lock(settings_mutex_);
            auto& renderer = options_.at(ps2 ? "pcsx2_renderer" : "swanstation_GPU_Renderer");
            const auto software = std::find(renderer.values.begin(), renderer.values.end(),
                                            ps2 ? "Software (HW)" : "Software");
            if (software == renderer.values.end())
              throw std::runtime_error("The core could not present hardware frames.");
            renderer.selected = static_cast<size_t>(software - renderer.values.begin());
          }
          audio_.Flush();
          if (card) StoreCard(card_path, card, card_size);
          if (!reopen()) throw std::runtime_error("The core could not restart after a graphics startup failure.");
          restore_card();
          hardware_deadline = Clock::now() + std::chrono::seconds(8);
        }
        if (paused_ && frame_ready_) {
          std::this_thread::sleep_for(std::chrono::milliseconds(5));
          next = Clock::now();
          continue;
        }
        step();
        if (!paused_) ++steps_;
        if (ps3_ && vulkan_.unsupported_sync())
          throw std::runtime_error("This RPCS3 core uses Vulkan synchronization AnyPS5 does not support.");
        next += frame_time;
        const auto now = Clock::now();
        if (next < now - frame_time) next = now;
        std::this_thread::sleep_until(next);
      }
      if (card) StoreCard(card_path, card, card_size);
    } catch (const std::exception& failure) {
      std::lock_guard<std::mutex> lock(settings_mutex_);
      error_ = failure.what();
    }
    if (loaded) unload();
    if (ps3_ && vulkan_.negotiated() && hardware_callbacks_.destroy) hardware_callbacks_.destroy();
    if (ps3_) vulkan_.Close();
    if (initialized) deinit();
    audio_.Close();
    if (dll) FreeLibrary(dll);
    active_ = nullptr;
    ended_ = true;
  }

  static std::atomic<RetroCoreSession*> active_;
  flutter::TextureRegistrar* registrar_;
  const std::string core_, disc_;
  const std::unique_ptr<ps1_netplay::Timeline> netplay_;
  const std::unique_ptr<Ps1MatchStorage> match_storage_;
  const std::string system_, saves_, content_;
  const std::string initial_resolution_;
  const std::map<std::string, std::string> initial_graphics_;
  const bool ps3_;
  const bool local_staging_;
  flutter::TextureVariant texture_;
  int64_t texture_id_ = -1;
  std::thread worker_;
  StereoOutput audio_;
  HardwareVideo hardware_;
  RetroVulkanVideo vulkan_;
  HardwareCallbacks hardware_callbacks_{};
  bool hardware_available_ = false;
  uint64_t hardware_frames_ = 0;
  std::mutex telemetry_mutex_;
  std::chrono::steady_clock::time_point last_frame_at_{};
  std::array<int64_t, 13> frame_intervals_{};
  int64_t video_frames_ = 0;
  double target_fps_ = 0;
  double audio_rate_ = 0;
  std::atomic<int64_t> steps_{0};
  std::atomic<int64_t> audio_frames_{0};
  std::atomic<bool> hardware_frame_{false};
  std::atomic<unsigned> frame_width_{0}, frame_height_{0};
  std::atomic<bool> stop_{false}, paused_{false}, ended_{false}, frame_ready_{false}, presented_{false};
  std::atomic<int> pixel_format_{0};
  std::atomic<float> aspect_{4.f / 3.f};
  std::mutex frame_mutex_, input_mutex_, settings_mutex_;
  std::mutex netplay_mutex_;
  std::mutex checkpoint_mutex_;
  std::atomic<bool> checkpoint_supported_{false};
  std::optional<CheckpointJob> checkpoint_;
  std::optional<uint32_t> replay_cursor_;
  std::deque<Ps1Ports> checkpoint_history_;
  std::atomic<bool> netplay_ready_{false};
  bool netplay_started_ = false;
  bool netplay_held_ = false;
  bool netplay_epoch_reset_ = false;
  bool local_prepared_ = false;
  uint32_t local_frame_ = 0;
  std::array<ps1_netplay::PadInput, 2> netplay_ports_{};
  std::vector<std::pair<uint32_t, std::string>> netplay_fingerprints_;
  std::shared_ptr<Frame> frame_;
  uint16_t buttons_ = 0;
  std::array<int16_t, 4> axes_{};
  std::map<std::string, Option> options_;
  bool options_changed_ = false;
  bool graphics_queued_ = false;
  bool graphics_applying_ = false;
  std::atomic<bool> suppress_frame_{false};
  std::chrono::steady_clock::time_point progress_until_{};
  std::string progress_label_;
  int32_t progress_percent_ = -1;
  std::string error_, resolution_error_;
};

std::atomic<RetroCoreSession*> RetroCoreSession::active_{nullptr};

RetroCoreHost::RetroCoreHost(flutter::BinaryMessenger* messenger, flutter::TextureRegistrar* textures)
    : textures_(textures), channel_(messenger, "anyps5/retro_core", &flutter::StandardMethodCodec::GetInstance()) {
  channel_.SetMethodCallHandler([this](const auto& call, auto result) { Handle(call, std::move(result)); });
}

RetroCoreHost::~RetroCoreHost() {
  channel_.SetMethodCallHandler(nullptr);
  if (session_) {
    session_->Stop();
    Release();
  }
}

void RetroCoreHost::Release() {
  auto session = std::move(session_);
  session->Join();
  const auto id = session->texture_id();
  if (id >= 0) textures_->UnregisterTexture(id, [session] {});
}

void RetroCoreHost::Handle(const flutter::MethodCall<Value>& call,
                           std::unique_ptr<flutter::MethodResult<Value>> result) {
  const auto& method = call.method_name();
  const auto* arguments = call.arguments();
  if (method == "start") {
    if (session_ && session_->ended()) Release();
    if (session_) {
      result->Error("busy", "An embedded game is already running");
      return;
    }
    const auto* fields = std::get_if<Map>(arguments);
    const auto* core = fields ? StringField(*fields, "core") : nullptr;
    const auto* disc = fields ? StringField(*fields, "disc") : nullptr;
    const auto* system = fields ? StringField(*fields, "system") : nullptr;
    const auto* saves = fields ? StringField(*fields, "saves") : nullptr;
    const auto* resolution = fields ? StringField(*fields, "internalResolution") : nullptr;
    if (!core || !disc || !system || !saves) {
      result->Error("argument", "The core, disc and storage paths are required");
      return;
    }
    try {
      std::optional<unsigned> netplay_seat;
      const auto seat = fields->find(Value("ps1NetplaySeat"));
      const auto* netplay_bios = StringField(*fields, "ps1NetplayBios");
      const auto local = fields->find(Value("ps1LocalStaging"));
      const auto* local_staging = local == fields->end() ? nullptr : std::get_if<bool>(&local->second);
      if (local != fields->end() && !local_staging) {
        result->Error("argument", "PS1 local staging must be a boolean");
        return;
      }
      if (seat != fields->end()) {
        const auto number = IntegerValue(seat->second);
        if (!number || *number < 0 || *number > 1 || !netplay_bios ||
            std::filesystem::u8path(*core).filename() != L"swanstation_libretro.dll" ||
            _wcsicmp(std::filesystem::u8path(*disc).extension().c_str(), L".cue") != 0) {
          result->Error("argument", "PS1 netplay requires a valid seat, SwanStation, a CUE disc and a verified BIOS");
          return;
        }
        netplay_seat = static_cast<unsigned>(*number);
      }
      std::map<std::string, std::string> graphics;
      const auto values = fields->find(Value("graphics"));
      if (values != fields->end()) {
        if (const auto* saved = std::get_if<Map>(&values->second)) {
          for (const auto& entry : *saved) {
            const auto* key = std::get_if<std::string>(&entry.first);
            const auto* value = std::get_if<std::string>(&entry.second);
            if (key && value) graphics.emplace(*key, *value);
          }
        }
      }
      session_ = std::make_shared<RetroCoreSession>(textures_, *core, *disc, *system, *saves,
                                                   resolution ? *resolution : "", std::move(graphics),
                                                   netplay_seat, netplay_bios ? *netplay_bios : "",
                                                   local_staging && *local_staging);
      if (!session_->Start()) throw std::runtime_error("Could not register the game surface");
      result->Success(Value(session_->texture_id()));
    } catch (const std::exception& failure) {
      if (session_) Release();
      result->Error("start", failure.what());
    }
    return;
  }
  if (!session_) {
    result->Success();
    return;
  }
  if (method == "status") {
    result->Success(Value(session_->Status()));
  } else if (method == "netplayStart") {
    result->Success(Value(session_->StartNetplay()));
  } else if (method == "ps1CheckpointHold") {
    result->Success(FrameValue(session_->HoldNetplay()));
  } else if (method == "ps1ResumeLocal") {
    result->Success(Value(session_->ResumeLocalNetplay()));
  } else if (method == "ps1CheckpointExport" || method == "ps1CheckpointImport") {
    const auto* fields = std::get_if<Map>(arguments);
    if (!fields) return result->Error("checkpoint", "Expected checkpoint arguments");
    const auto digest_field = fields->find(Value("discHash"));
    const auto* digest = digest_field == fields->end() ? nullptr
                                                       : std::get_if<CheckpointBytes>(&digest_field->second);
    if (!digest || digest->size() != Ps1DiscHash{}.size())
      return result->Error("checkpoint", "Expected a 32-byte disc hash");
    Ps1DiscHash hash{};
    std::copy(digest->begin(), digest->end(), hash.begin());
    CheckpointBytes restore;
    std::optional<uint32_t> frame;
    if (method == "ps1CheckpointImport") {
      const auto state_field = fields->find(Value("state"));
      const auto* state = state_field == fields->end() ? nullptr
                                                       : std::get_if<CheckpointBytes>(&state_field->second);
      if (!state || state->empty() || state->size() > kMaxPs1Checkpoint)
        return result->Error("checkpoint", "Invalid portable checkpoint size");
      const auto frame_field = fields->find(Value("frame"));
      const auto number = frame_field == fields->end() ? std::nullopt : IntegerValue(frame_field->second);
      if (!number || *number < 0 || *number > ps1_netplay::Timeline::kMaxFrame)
        return result->Error("checkpoint", "Invalid portable checkpoint frame");
      frame = static_cast<uint32_t>(*number);
      restore = *state;
    }
    const auto id = session_->RequestCheckpoint(hash, std::move(restore), frame);
    if (!id) return result->Error("checkpoint", "This core cannot run that checkpoint operation now");
    result->Success(Value(*id));
  } else if (method == "ps1CheckpointHistory") {
    const auto first = arguments ? IntegerValue(*arguments) : std::nullopt;
    if (!first || *first < 0 || *first > ps1_netplay::Timeline::kMaxFrame)
      return result->Error("checkpoint", "Invalid first history frame");
    auto history = session_->CheckpointHistory(static_cast<uint32_t>(*first));
    if (!history) return result->Error("checkpoint", "The requested input history is unavailable");
    result->Success(Value(std::move(*history)));
  } else if (method == "ps1CheckpointReplay") {
    const auto reject = [&] { result->Error("checkpoint", "Invalid checkpoint replay inputs"); };
    const auto* fields = std::get_if<Map>(arguments);
    if (!fields) return reject();
    const auto frame_field = fields->find(Value("frame"));
    const auto first = frame_field == fields->end() ? std::nullopt : IntegerValue(frame_field->second);
    const auto frames_field = fields->find(Value("frames"));
    const auto* frames = frames_field == fields->end() ? nullptr : std::get_if<List>(&frames_field->second);
    if (!first || *first < 0 || *first > ps1_netplay::Timeline::kMaxFrame ||
        !frames || frames->empty() || frames->size() > kPs1CatchupBatch)
      return reject();
    std::vector<Ps1Ports> batch;
    batch.reserve(frames->size());
    for (const auto& frame : *frames) {
      const auto* ports = std::get_if<List>(&frame);
      if (!ports || ports->size() != 2) return reject();
      Ps1Ports input{};
      for (size_t seat = 0; seat < input.size(); ++seat) {
        const auto* pad = std::get_if<List>(&(*ports)[seat]);
        if (!pad || pad->size() != 5) return reject();
        const auto buttons = IntegerValue(pad->front());
        if (!buttons || *buttons < 0 || *buttons > UINT16_MAX) return reject();
        input[seat].buttons = static_cast<uint16_t>(*buttons);
        for (size_t axis = 0; axis < input[seat].axes.size(); ++axis) {
          const auto value = IntegerValue((*pad)[axis + 1]);
          if (!value || *value < INT16_MIN || *value > INT16_MAX) return reject();
          input[seat].axes[axis] = static_cast<int16_t>(*value);
        }
      }
      batch.push_back(input);
    }
    const auto id = session_->RequestCatchup(static_cast<uint32_t>(*first), std::move(batch));
    if (!id) return result->Error("checkpoint", "The guest cannot replay from that frame");
    result->Success(Value(*id));
  } else if (method == "ps1CheckpointResult" || method == "ps1CheckpointCancel") {
    const auto id = arguments ? IntegerValue(*arguments) : std::nullopt;
    if (!id) return result->Error("checkpoint", "Expected a checkpoint request ID");
    if (method == "ps1CheckpointResult") {
      result->Success(session_->TakeCheckpoint(*id));
    } else {
      session_->CancelCheckpoint(*id);
      result->Success();
    }
  } else if (method == "netplaySync") {
    const auto fail = [&] { result->Error("netplayInput", "The PS1 netplay input exchange was rejected"); };
    const auto* fields = std::get_if<Map>(arguments);
    if (!fields) return fail();
    const auto remote = fields->find(Value("remote"));
    const auto* samples = remote == fields->end() ? nullptr : std::get_if<List>(&remote->second);
    if (!samples || samples->size() > 32) return fail();
    std::optional<uint32_t> acknowledged;
    const auto ack = fields->find(Value("acknowledgedFrame"));
    if (ack != fields->end() && !std::holds_alternative<std::monostate>(ack->second)) {
      const auto number = IntegerValue(ack->second);
      if (!number || *number < 0 || *number > ps1_netplay::Timeline::kMaxFrame) return fail();
      acknowledged = static_cast<uint32_t>(*number);
    }
    std::vector<ps1_netplay::FrameInput> inputs;
    inputs.reserve(samples->size());
    for (const auto& sample : *samples) {
      const auto* values = std::get_if<List>(&sample);
      if (!values || values->size() != 6) return fail();
      const auto frame = IntegerValue((*values)[0]);
      const auto buttons = IntegerValue((*values)[1]);
      if (!frame || *frame < 0 || *frame > ps1_netplay::Timeline::kMaxFrame ||
          !buttons || *buttons < 0 || *buttons > UINT16_MAX) return fail();
      ps1_netplay::PadInput input{static_cast<uint16_t>(*buttons), {}};
      for (size_t index = 0; index < input.axes.size(); ++index) {
        const auto axis = IntegerValue((*values)[index + 2]);
        if (!axis || *axis < INT16_MIN || *axis > INT16_MAX) return fail();
        input.axes[index] = static_cast<int16_t>(*axis);
      }
      inputs.push_back({static_cast<uint32_t>(*frame), input});
    }
    auto update = session_->SyncNetplay(inputs, acknowledged);
    if (!update) return fail();
    result->Success(Value(std::move(*update)));
  } else if (method == "stop") {
    session_->Stop();
    result->Success();
  } else if (method == "release") {
    if (session_->ended()) Release();
    result->Success();
  } else if (method == "pause") {
    const auto* pause = std::get_if<bool>(arguments);
    if (pause) session_->Pause(*pause);
    result->Success();
  } else if (method == "input") {
    const auto* input = std::get_if<List>(arguments);
    if (input && input->size() == 5) {
      std::array<int16_t, 4> axes{};
      for (size_t index = 0; index < axes.size(); ++index) {
        if (const auto* axis = std::get_if<int32_t>(&(*input)[index + 1])) {
          axes[index] = static_cast<int16_t>(std::clamp(*axis, -32768, 32767));
        }
      }
      if (const auto* mask = std::get_if<int32_t>(&input->front())) {
        session_->SetInput(static_cast<uint16_t>(*mask), axes);
      }
    }
    result->Success();
  } else if (method == "tuningOptions") {
    const auto* fields = std::get_if<Map>(arguments);
    if (!fields) {
      result->Success(Value(false));
      return;
    }
    const auto expected = fields->find(Value("expected"));
    const auto values = fields->find(Value("values"));
    const auto* expected_options = expected == fields->end() ? nullptr : std::get_if<Map>(&expected->second);
    const auto* candidate_options = values == fields->end() ? nullptr : std::get_if<Map>(&values->second);
    result->Success(Value(expected_options && candidate_options &&
                          session_->SetTuningOptions(*expected_options, *candidate_options)));
  } else if (method == "option") {
    const auto* fields = std::get_if<Map>(arguments);
    const auto* key = fields ? StringField(*fields, "key") : nullptr;
    const auto* value = fields ? StringField(*fields, "value") : nullptr;
    result->Success(Value(key && value && session_->SetOption(*key, *value)));
  } else {
    result->NotImplemented();
  }
}
