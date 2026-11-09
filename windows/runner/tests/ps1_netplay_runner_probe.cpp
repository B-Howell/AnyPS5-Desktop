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

#include <iomanip>
#include <iostream>
#include <flutter/method_result_functions.h>

class ProbeTexture final : public flutter::TextureRegistrar {
 public:
  int64_t RegisterTexture(flutter::TextureVariant* texture) override {
    texture_ = texture;
    return ++registered_;
  }

  bool MarkTextureFrameAvailable(int64_t) override {
    const auto* frame = std::get<flutter::PixelBufferTexture>(*texture_).CopyPixelBuffer(0, 0);
    if (!frame) return false;
    frame->release_callback(frame->release_context);
    ++published_;
    return true;
  }

  void UnregisterTexture(int64_t, std::function<void()> complete) override {
    if (complete) complete();
  }

  bool UnregisterTexture(int64_t) override { return true; }
  uint64_t published() const { return published_; }

 private:
  flutter::TextureVariant* texture_ = nullptr;
  int64_t registered_ = 0;
  std::atomic<uint64_t> published_{0};
};

class ProbeMessenger final : public flutter::BinaryMessenger {
 public:
  void Send(const std::string&, const uint8_t*, size_t, flutter::BinaryReply) const override {}
  void SetMessageHandler(const std::string&, flutter::BinaryMessageHandler handler) override {
    handler_ = std::move(handler);
  }

  Value Call(const std::string& method, Value arguments = {}, const char* expected_error = nullptr) {
    const auto& codec = flutter::StandardMethodCodec::GetInstance();
    const auto message = codec.EncodeMethodCall({method, std::make_unique<Value>(std::move(arguments))});
    Value value;
    std::string error;
    bool replied = false;
    flutter::MethodResultFunctions<Value> response(
        [&](const Value* reply) { if (reply) value = *reply; },
        [&](const auto& code, const auto& message, const Value*) {
          error = code;
          if (!expected_error) error += ": " + message;
        },
        [&] { error = "unimplemented"; });
    handler_(message->data(), message->size(), [&](const uint8_t* reply, size_t size) {
      replied = codec.DecodeAndProcessResponseEnvelope(reply, size, &response);
    });
    if (!replied || error != (expected_error ? expected_error : ""))
      throw std::runtime_error(method + " returned " + error);
    return value;
  }

  Map Wait(const char* key) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    while (std::chrono::steady_clock::now() < deadline) {
      auto status = std::get<Map>(Call("status"));
      const auto field = status.find(Value(key));
      if (field != status.end() &&
          (!std::holds_alternative<bool>(field->second) || std::get<bool>(field->second))) return status;
      if (std::get<bool>(status.at(Value("ended"))))
        throw std::runtime_error(std::get<std::string>(status.at(Value("error"))));
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    throw std::runtime_error(std::string("Timed out waiting for ") + key);
  }

  Value Take(const Value& id) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (std::chrono::steady_clock::now() < deadline) {
      auto reply = Call("ps1CheckpointResult", id);
      if (!std::holds_alternative<std::monostate>(reply)) return reply;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    throw std::runtime_error("Timed out waiting for a checkpoint");
  }

 private:
  flutter::BinaryMessageHandler handler_;
};

int VerifyReplacement(ProbeTexture& texture, char** argv) {
  ProbeMessenger messenger;
  RetroCoreHost host(&messenger, &texture);
  const auto system = std::filesystem::u8path(argv[3]).parent_path().u8string();
  Map ordinary{{Value("core"), Value(std::string(argv[1]))}, {Value("disc"), Value(std::string(argv[2]))},
               {Value("system"), Value(system)}, {Value("saves"), Value(std::string(argv[6]))}};
  auto match = ordinary;
  match.emplace(Value("ps1NetplaySeat"), Value(0));
  match.emplace(Value("ps1NetplayBios"), Value(std::string(argv[3])));
  match.emplace(Value("ps1NetplayCpu"), Value("Recompiler"));
  const auto texture_id = messenger.Call("start", Value(ordinary));
  const auto source = messenger.Wait("localBlankCardCheckpoint").at(Value("localBlankCardCheckpoint"));
  constexpr auto crop = "swanstation_Display_CropMode";
  const auto crop_value = [crop](const char* value) {
    return Value(Map{{Value("key"), Value(crop)}, {Value("value"), Value(value)}});
  };
  if (!std::get<bool>(messenger.Call("option", crop_value("Overscan"))))
    throw std::runtime_error("Could not configure the original game");
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  messenger.Call("pause", Value(true));
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  const auto fingerprint = [] {
    const auto dll = GetModuleHandleW(L"swanstation_libretro.dll");
    const auto* ram = static_cast<const uint8_t*>(Symbol<void* (*)(unsigned)>(dll, "retro_get_memory_data")(2));
    return NetplayFingerprint(ram, 2 * 1024 * 1024);
  };
  const auto before = fingerprint();
  const CheckpointBytes digest(32, 1);
  Map source_args{{Value("texture"), texture_id}, {Value("source"), source}};
  auto park_args = source_args;
  park_args.emplace(Value("discHash"), Value(digest));
  auto blank = messenger.Take(messenger.Call("ps1LocalCheckpointPark", Value(park_args)));
  if (!std::holds_alternative<Map>(blank)) throw std::runtime_error("Could not park the source");
  if (std::get<bool>(messenger.Call("option", crop_value("None"))))
    throw std::runtime_error("The parked source accepted a settings change");
  messenger.Call("ps1LocalCheckpointDetach", Value(Map{{Value("texture"), Value(123)}, {Value("source"), source}}),
                 "checkpoint");
  const auto ticket = messenger.Call("ps1LocalCheckpointDetach", Value(source_args));
  auto failed = match;
  failed.at(Value("core")) = Value(std::string(argv[4]));
  messenger.Call("start", Value(failed));
  messenger.Wait("ended");
  messenger.Call("start", Value(match));
  messenger.Wait("netplayReady");
  Map restore{{Value("discHash"), Value(digest)}, {Value("frame"), Value(0)},
              {Value("state"), std::get<Map>(blank).at(Value("state"))}};
  if (!std::get<bool>(messenger.Take(messenger.Call("ps1CheckpointImport", Value(restore)))) ||
      fingerprint() != before) throw std::runtime_error("The match lost the source frame");
  messenger.Call("ps1LocalCheckpointReopen", ticket, "busy");
  messenger.Call("ps1LocalCheckpointDiscard", ticket, "busy");
  messenger.Call("stop");
  messenger.Wait("ended");
  const auto core_path = std::filesystem::u8path(argv[1]);
  auto disabled = core_path;
  disabled += L".unavailable";
  const auto scratch = std::filesystem::u8path(argv[6]).parent_path();
  if (!core_path.is_absolute() || core_path.parent_path() != scratch ||
      core_path.filename() != L"swanstation_libretro.dll" || std::filesystem::exists(disabled))
    throw std::runtime_error("The replacement test requires a private core copy");
  std::filesystem::rename(core_path, disabled);
  try {
    messenger.Call("ps1LocalCheckpointReopen", ticket);
    const auto failure = messenger.Wait("ended").at(Value("error"));
    if (std::get<std::string>(failure).find("Could not load") == std::string::npos)
      throw std::runtime_error("The missing recovery core did not fail as expected");
  } catch (...) {
    std::filesystem::rename(disabled, core_path);
    throw;
  }
  std::filesystem::rename(disabled, core_path);
  const auto recovered_texture = messenger.Call("ps1LocalCheckpointReopen", ticket);
  const auto recovered = messenger.Wait("ps1RecoveredSource");
  auto card_path = std::filesystem::u8path(argv[6]) / std::filesystem::u8path(argv[2]).stem();
  card_path += L".srm";
  CheckpointBytes source_card(std::filesystem::file_size(card_path));
  RestoreCard(card_path, source_card.data(), source_card.size());
  if (source_card.empty()) throw std::runtime_error("The source did not save its scratch card");
  auto disk_marker = source_card;
  disk_marker.back() ^= 1;
  StoreCard(card_path, disk_marker.data(), disk_marker.size());
  const auto& options = std::get<Map>(recovered.at(Value("options")));
  const auto& restored_crop = std::get<Map>(options.at(Value(crop))).at(Value("activeValue"));
  if (IntegerValue(recovered_texture) == IntegerValue(texture_id) ||
      IntegerValue(recovered.at(Value("ps1RecoveredSource"))) != IntegerValue(source) ||
      std::get<std::string>(restored_crop) != "Overscan" || fingerprint() != before)
    throw std::runtime_error("The original frame was not recovered");
  messenger.Call("pause", Value(false));
  if (!std::get<bool>(messenger.Wait("startupVisible").at(Value("hardware"))))
    throw std::runtime_error("The original renderer was not recovered");
  messenger.Call("stop");
  messenger.Wait("ended");
  CheckpointBytes saved_card(source_card.size());
  RestoreCard(card_path, saved_card.data(), saved_card.size());
  if (saved_card != disk_marker)
    throw std::runtime_error("Stopping a provisional recovery wrote to the original card");
  const auto retry_texture = messenger.Call("ps1LocalCheckpointReopen", ticket);
  messenger.Wait("ps1RecoveredSource");
  if (fingerprint() != before) throw std::runtime_error("Retry lost the original frame");
  const Value acceptance(Map{{Value("texture"), retry_texture}, {Value("source"), ticket}});
  messenger.Call("ps1LocalCheckpointAccept", acceptance, "checkpoint");
  messenger.Call("pause", Value(false));
  messenger.Wait("startupVisible");
  messenger.Call("ps1LocalCheckpointAccept",
                 Value(Map{{Value("texture"), recovered_texture}, {Value("source"), ticket}}), "checkpoint");
  if (!std::get<bool>(messenger.Call("ps1LocalCheckpointAccept", acceptance)))
    throw std::runtime_error("The recovered frame was not accepted");
  messenger.Call("ps1LocalCheckpointReopen", ticket, "checkpoint");
  messenger.Call("stop");
  messenger.Wait("ended");
  RestoreCard(card_path, saved_card.data(), saved_card.size());
  if (saved_card != source_card)
    throw std::runtime_error("Accepted recovery did not save the restored card");
  std::cout << "Native method channel replaced the PS1 worker and recovered its original frame." << std::endl;
  return 0;
}

int main(int argc, char** argv) {
  if (argc < 5 || argc > 7) return 2;
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
  ProbeTexture texture;
  if (argc == 7 && std::string_view(argv[5]) == "replace") {
    try {
      return VerifyReplacement(texture, argv);
    } catch (const std::exception& failure) {
      std::cerr << failure.what() << '\n';
      return 8;
    }
  }
  const auto seat = std::stoul(argv[4]);
  const bool local_staging = argc == 6 && std::string_view(argv[5]) == "local";
  const bool recompiler = argc == 6 && std::string_view(argv[5]) == "recompiler";
  if (argc == 6 && !local_staging && !recompiler) return 2;
  const bool ordinary = argc == 7 && std::string_view(argv[5]) == "ordinary";
  if (argc == 7 && !ordinary) return 2;
  const auto bios_directory = std::filesystem::u8path(argv[3]).parent_path().u8string();
  RetroCoreSession session(&texture, argv[1], argv[2], ordinary ? bios_directory : "",
                           ordinary ? argv[6] : "", "", {},
                           ordinary ? std::nullopt : std::optional<unsigned>(seat), argv[3], local_staging,
                           std::nullopt, std::nullopt, {},
                           recompiler ? Ps1MatchCpu::kRecompiler : Ps1MatchCpu::kCachedInterpreter);
  if (!session.Start()) return 3;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
  while (std::chrono::steady_clock::now() < deadline) {
    const auto status = session.Status();
    if (std::get<bool>(status.at(Value("ended")))) {
      std::cerr << std::get<std::string>(status.at(Value("error"))) << '\n';
      return 4;
    }
    if (std::get<bool>(status.at(Value(ordinary ? "startupVisible" : "netplayReady")))) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  if (!std::get<bool>(session.Status().at(Value(ordinary ? "startupVisible" : "netplayReady")))) return 4;
  std::cout << "ready" << std::endl;
  std::string command;
  while (std::cin >> command && command != "quit") {
    if (command == "published") {
      std::cout << texture.published() << std::endl;
      continue;
    }
    if (ordinary && (command == "pause" || command == "resume")) {
      session.Pause(command == "pause");
      std::cout << command << std::endl;
      continue;
    }
    if (command == "renderer") {
      const auto status = session.Status();
      std::cout << (std::get<bool>(status.at(Value("hardware"))) ? "hardware" : "software") << std::endl;
      continue;
    }
    if (command == "cpu") {
      const auto status = session.Status();
      const auto& options = std::get<Map>(status.at(Value("options")));
      const auto& cpu = std::get<Map>(options.at(Value("swanstation_CPU_ExecutionMode")));
      std::cout << std::get<std::string>(cpu.at(Value("activeValue"))) << std::endl;
      continue;
    }
    if (command == "history") {
      uint32_t first;
      if (!(std::cin >> first)) return 7;
      const auto history = session.CheckpointHistory(first);
      if (!history) return 7;
      const auto& frames = std::get<List>(history->at(Value("frames")));
      std::cout << frames.size();
      for (const auto& frame : frames) {
        const auto& ports = std::get<List>(frame);
        for (const auto& pad : ports) std::cout << ' ' << std::get<int32_t>(std::get<List>(pad).front());
      }
      std::cout << std::endl;
      continue;
    }
    if (command == "replay") {
      uint32_t first, count;
      if (!(std::cin >> first >> count) || count == 0 || count > 120) return 7;
      std::vector<std::array<ps1_netplay::PadInput, 2>> frames(count);
      for (auto& frame : frames) {
        for (auto& pad : frame) {
          unsigned buttons;
          if (!(std::cin >> buttons) || buttons > UINT16_MAX) return 7;
          pad.buttons = static_cast<uint16_t>(buttons);
        }
      }
      const auto request = session.RequestCatchup(first, std::move(frames));
      if (!request) {
        std::cout << "unavailable" << std::endl;
        continue;
      }
      const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(3);
      while (std::chrono::steady_clock::now() < until) {
        const auto value = session.TakeCheckpoint(*request);
        if (const auto* applied = std::get_if<bool>(&value)) {
          std::cout << (*applied ? "replayed" : "rejected") << std::endl;
          break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
      if (std::chrono::steady_clock::now() >= until) return 7;
      continue;
    }
    if (command == "local-support") {
      const auto status = session.Status();
      const auto available = status.find(Value("localBlankCardCheckpoint"));
      std::cout << (available != status.end() && IntegerValue(available->second) ? "yes" : "no") << std::endl;
      continue;
    }
    if (ordinary && command == "resume-checkpoint") {
      const auto status = session.Status();
      const auto entry = status.find(Value("localBlankCardCheckpoint"));
      const auto request = session.RequestOrdinaryCheckpointResume(
          entry == status.end() ? 0 : IntegerValue(entry->second).value_or(0));
      if (!request) {
        std::cout << "unavailable" << std::endl;
        continue;
      }
      const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(3);
      while (std::chrono::steady_clock::now() < until) {
        const auto value = session.TakeCheckpoint(*request);
        if (const auto* restored = std::get_if<bool>(&value)) {
          std::cout << (*restored ? "resumed" : "rejected") << std::endl;
          break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
      if (std::chrono::steady_clock::now() >= until) return 7;
      continue;
    }
    if (ordinary && command == "erase-card-tail") {
      size_t count;
      const auto status = session.Status();
      if (!(std::cin >> count) || count == 0 || count > 128 ||
          !std::get<bool>(status.at(Value("ordinaryCheckpointParked")))) return 7;
      const auto dll = GetModuleHandleW(L"swanstation_libretro.dll");
      auto* card = static_cast<uint8_t*>(Symbol<void* (*)(unsigned)>(dll, "retro_get_memory_data")(0));
      const auto size = Symbol<size_t (*)(unsigned)>(dll, "retro_get_memory_size")(0);
      if (!card || size != 128 * 1024) return 7;
      std::fill_n(card + size - count, count, uint8_t{0});
      std::cout << "erased" << std::endl;
      continue;
    }
    if (command == "checkpoint" || command == "blank-checkpoint" || command == "cancel-blank" ||
        command == "stale-blank" || command == "park-checkpoint" || command == "cancel-park" ||
        command == "restore") {
      unsigned digest_byte;
      std::string path;
      if (!(std::cin >> digest_byte >> std::quoted(path)) || digest_byte > UINT8_MAX) return 7;
      std::array<uint8_t, 32> digest{};
      digest[0] = static_cast<uint8_t>(digest_byte);
      CheckpointBytes restore;
      std::optional<uint32_t> first;
      if (command == "restore") {
        uint32_t frame;
        if (!(std::cin >> frame)) return 7;
        first = frame;
        const auto size = std::filesystem::file_size(std::filesystem::u8path(path));
        if (!size || size > kMaxPs1Checkpoint) return 7;
        restore.resize(static_cast<size_t>(size));
        std::ifstream file(std::filesystem::u8path(path), std::ios::binary);
        if (!file.read(reinterpret_cast<char*>(restore.data()), static_cast<std::streamsize>(restore.size()))) return 7;
      }
      std::optional<int64_t> request;
      if (command == "checkpoint" || command == "restore") {
        request = session.RequestCheckpoint(digest, std::move(restore), first);
      } else {
        const auto status = session.Status();
        const auto entry = status.find(Value("localBlankCardCheckpoint"));
        const auto source = entry == status.end() ? 0 : IntegerValue(entry->second).value_or(0);
        request = session.RequestBlankCardCheckpoint(source + (command == "stale-blank" ? 1 : 0), digest,
                                                     command == "park-checkpoint" || command == "cancel-park");
      }
      if (!request) {
        std::cout << "unavailable" << std::endl;
        continue;
      }
      if (command == "cancel-park") {
        const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(3);
        while (!std::get<bool>(session.Status().at(Value("ordinaryCheckpointParked")))) {
          if (std::chrono::steady_clock::now() >= until) return 7;
          std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
      }
      if (command == "cancel-blank" || command == "cancel-park") {
        session.CancelCheckpoint(*request);
        const auto discarded = session.TakeCheckpoint(*request);
        const auto* available = std::get_if<bool>(&discarded);
        if (!available || *available) return 7;
        std::cout << "cancelled" << std::endl;
        continue;
      }
      const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(3);
      while (std::chrono::steady_clock::now() < until) {
        const auto value = session.TakeCheckpoint(*request);
        if (const auto* snapshot = std::get_if<Map>(&value)) {
          const auto& bytes = std::get<CheckpointBytes>(snapshot->at(Value("state")));
          const auto frame = std::get<int64_t>(snapshot->at(Value("frame")));
          if (command == "restore" || bytes.size() <= 40 || bytes[8] != digest[0]) return 7;
          std::ofstream file(std::filesystem::u8path(path), std::ios::binary);
          if (!file.write(reinterpret_cast<const char*>(bytes.data()),
                          static_cast<std::streamsize>(bytes.size()))) return 7;
          file.close();
          if (!file) return 7;
          std::cout << "checkpoint " << frame << ' ' << bytes.size() << std::endl;
          break;
        }
        if (const auto* restored = std::get_if<bool>(&value)) {
          if (command == "checkpoint") return 7;
          std::cout << (*restored ? "restored" : "rejected") << std::endl;
          break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
      if (std::chrono::steady_clock::now() >= until) return 7;
      continue;
    }
    if (command == "fingerprint") {
      // The driver withholds remote input before reading the held worker.
      const auto dll = GetModuleHandleW(L"swanstation_libretro.dll");
      const auto* ram = static_cast<const uint8_t*>(Symbol<void* (*)(unsigned)>(dll, "retro_get_memory_data")(2));
      if (!ram) return 7;
      std::cout << NetplayFingerprint(ram, 2 * 1024 * 1024) << std::endl;
      continue;
    }
    if (command == "hold") {
      const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(3);
      while (std::chrono::steady_clock::now() < until) {
        if (const auto frame = session.HoldNetplay()) {
          std::cout << "held " << *frame << std::endl;
          break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
      if (std::chrono::steady_clock::now() >= until) return 7;
      continue;
    }
    if (command == "resume-local") {
      std::cout << (session.ResumeLocalNetplay() ? "resumed" : "unavailable") << std::endl;
      continue;
    }
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
