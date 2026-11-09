// Build beside the runner with the Flutter Windows wrapper libraries. This
// uses the real native worker and an in-memory texture without opening a UI.
#include <windows.h>
#include <mmsystem.h>

static MMRESULT WINAPI SilentWaveOutWrite(HWAVEOUT, LPWAVEHDR header, UINT) {
  header->dwFlags = (header->dwFlags & ~WHDR_INQUEUE) | WHDR_DONE;
  return MMSYSERR_NOERROR;
}

#define waveOutWrite SilentWaveOutWrite
#include "../retro_core_host.cpp"
#undef waveOutWrite

#include <iostream>

class ProbeTexture final : public flutter::TextureRegistrar {
 public:
  int64_t RegisterTexture(flutter::TextureVariant* texture) override {
    texture_ = texture;
    return 1;
  }

  bool MarkTextureFrameAvailable(int64_t) override {
    const auto* frame = std::get<flutter::PixelBufferTexture>(*texture_).CopyPixelBuffer(0, 0);
    if (!frame) return false;
    frame->release_callback(frame->release_context);
    return true;
  }

  void UnregisterTexture(int64_t, std::function<void()> complete) override {
    if (complete) complete();
  }

  bool UnregisterTexture(int64_t) override { return true; }

 private:
  flutter::TextureVariant* texture_ = nullptr;
};

int main(int argc, char** argv) {
  if (argc != 5) return 2;
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
  ProbeTexture texture;
  const auto seat = std::stoul(argv[4]);
  RetroCoreSession session(&texture, argv[1], argv[2], "", "", "", {}, seat, argv[3]);
  if (!session.Start()) return 3;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
  while (std::chrono::steady_clock::now() < deadline) {
    const auto status = session.Status();
    if (std::get<bool>(status.at(Value("ended")))) {
      std::cerr << std::get<std::string>(status.at(Value("error"))) << '\n';
      return 4;
    }
    if (std::get<bool>(status.at(Value("netplayReady")))) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  if (!std::get<bool>(session.Status().at(Value("netplayReady")))) return 4;
  std::cout << "ready" << std::endl;
  std::string command;
  while (std::cin >> command && command != "quit") {
    if (command == "start") {
      std::cout << (session.StartNetplay() ? "started" : "error") << std::endl;
      continue;
    }
    if (command == "pad") {
      unsigned mask;
      if (!(std::cin >> mask) || mask > UINT16_MAX) return 5;
      session.SetInput(static_cast<uint16_t>(mask), {});
      std::cout << "pad" << std::endl;
      continue;
    }
    if (command == "read") {
      // The probe only requests RAM after it holds both peers on a known frame
      // by withholding their next input. This is never a launcher method.
      size_t offset, count;
      if (!(std::cin >> offset >> count) || count > 256 || offset > 2 * 1024 * 1024 ||
          count > 2 * 1024 * 1024 - offset) return 5;
      const auto dll = GetModuleHandleW(L"swanstation_libretro.dll");
      if (!dll) return 5;
      const auto* ram = static_cast<const uint8_t*>(Symbol<void* (*)(unsigned)>(dll, "retro_get_memory_data")(2));
      if (!ram) return 5;
      constexpr char digits[] = "0123456789abcdef";
      for (size_t index = 0; index < count; ++index) {
        const auto byte = ram[offset + index];
        std::cout << digits[byte >> 4] << digits[byte & 15];
      }
      std::cout << std::endl;
      continue;
    }
    if (command != "sync") return 5;
    int64_t acknowledgement;
    unsigned count;
    if (!(std::cin >> acknowledgement >> count) || acknowledgement < -1 ||
        acknowledgement > ps1_netplay::Timeline::kMaxFrame || count > 32) return 5;
    std::vector<ps1_netplay::FrameInput> remote;
    for (unsigned index = 0; index < count; ++index) {
      unsigned frame, buttons;
      if (!(std::cin >> frame >> buttons) || buttons > UINT16_MAX) return 5;
      remote.push_back({frame, {static_cast<uint16_t>(buttons), {}}});
    }
    const auto received = session.SyncNetplay(
        remote, acknowledgement < 0 ? std::nullopt
                                    : std::optional<uint32_t>(static_cast<uint32_t>(acknowledgement)));
    if (!received) {
      const auto status = session.Status();
      std::cerr << std::get<std::string>(status.at(Value("error"))) << '\n';
      return 6;
    }
    const auto& state = *received;
    const auto& local = std::get<List>(state.at(Value("local")));
    std::cout << std::get<int64_t>(state.at(Value("frame"))) << ' '
              << IntegerValue(state.at(Value("receivedFrame"))).value_or(-1) << ' ' << local.size();
    for (const auto& row : local) {
      const auto& input = std::get<List>(row);
      std::cout << ' ' << *IntegerValue(input[0]) << ' ' << *IntegerValue(input[1]);
    }
    const auto& fingerprints = std::get<List>(state.at(Value("fingerprints")));
    std::cout << ' ' << fingerprints.size();
    for (const auto& row : fingerprints) {
      const auto& hash = std::get<List>(row);
      std::cout << ' ' << *IntegerValue(hash[0]) << ' ' << std::get<std::string>(hash[1]);
    }
    std::cout << std::endl;
  }
  session.Stop();
  session.Join();
  const auto status = session.Status();
  return std::get<std::string>(status.at(Value("error"))).empty() ? 0 : 7;
}
