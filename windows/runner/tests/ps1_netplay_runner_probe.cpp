// Build beside the runner with the Flutter Windows wrapper libraries. This
// uses the real native worker and an in-memory texture without opening a UI.
#include "ps1_probe_host.h"

#include <charconv>
#include <iomanip>
#include <iostream>
#include <flutter/method_result_functions.h>

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

void VerifyIsolatedCores(char** argv) {
  using Slot = RetroCoreSession::CallbackSlot;
  constexpr uint32_t kSplit = 240;
  constexpr uint32_t kFinish = 480;
  ProbeTexture primary_texture, presentation_texture, rejected_texture;
  std::atomic<size_t> audio_frames[2]{};
  const auto make = [&](ProbeTexture& texture, const char* core, Slot slot, uint16_t mask,
                        uint32_t limit) {
    std::vector<uint16_t> trace(limit, mask);
    trace[0] = trace[1] = 0;
    return std::make_unique<RetroCoreSession>(
        &texture, core, argv[2], "", "", "", std::map<std::string, std::string>{}, 0u,
        argv[3], false, std::nullopt, std::nullopt, std::vector<std::string>{},
        Ps1MatchCpu::kCachedInterpreter, nullptr, true,
        [&, slot](const int16_t*, size_t frames) { audio_frames[static_cast<size_t>(slot)] += frames; },
        std::move(trace), slot);
  };
  const auto ready = [](RetroCoreSession& worker) {
    if (!worker.Start()) throw std::runtime_error("Could not start the isolated core");
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
    while (std::chrono::steady_clock::now() < deadline) {
      const auto status = worker.Status();
      if (std::get<bool>(status.at(Value("ended"))))
        throw std::runtime_error(std::get<std::string>(status.at(Value("error"))));
      if (std::get<bool>(status.at(Value("netplayReady")))) return;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    throw std::runtime_error("Timed out opening the isolated core");
  };
  auto primary = make(primary_texture, argv[1], Slot::kPrimary, 8, kFinish);
  ready(*primary);
  const auto expect_rejected = [&](const char* core, Slot slot, std::string_view expected) {
    auto rejected = make(rejected_texture, core, slot, 256, kFinish);
    try {
      ready(*rejected);
    } catch (const std::runtime_error& error) {
      if (error.what() == expected) return;
      throw;
    }
    throw std::runtime_error("The callback ownership conflict was not rejected");
  };
  expect_rejected(argv[1], Slot::kPresentation, "The emulator DLL instance already has a callback owner.");
  expect_rejected(argv[6], Slot::kPrimary, "The emulator callback slot is already in use.");
  auto presentation = make(presentation_texture, argv[6], Slot::kPresentation, 256, kFinish);
  ready(*presentation);

  uint32_t sent[2]{};
  auto pump = [&](RetroCoreSession& worker, unsigned index, uint32_t target, uint16_t mask, uint32_t limit) {
    const auto status = worker.SyncNetplay({}, std::nullopt);
    if (!status) throw std::runtime_error("The isolated core stopped");
    std::optional<uint32_t> ack;
    for (const auto& row : std::get<List>(status->at(Value("local")))) {
      const auto& input = std::get<List>(row);
      ack = static_cast<uint32_t>(*IntegerValue(input[0]));
      if (*IntegerValue(input[1]) != (*ack >= 2 && *ack < limit ? mask : 0))
        throw std::runtime_error("An isolated core captured the other worker's input");
    }
    const auto frame = static_cast<uint32_t>(*IntegerValue(status->at(Value("frame"))));
    std::vector<ps1_netplay::FrameInput> inputs;
    while (sent[index] < std::min(target, frame + 12))
      inputs.push_back({sent[index]++, {}});
    const auto update = worker.SyncNetplay(inputs, ack);
    if (!update) throw std::runtime_error("The isolated core rejected its inputs");
    return IntegerValue(update->at(Value("confirmedFrame"))).value_or(-1);
  };
  if (!primary->StartNetplay()) throw std::runtime_error("Could not start the primary timeline");
  const auto idle_video = presentation_texture.published();
  const auto primary_video = primary_texture.published();
  const auto idle_audio = audio_frames[1].load();
  const auto wait = [&](const auto& complete) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
    while (!complete()) {
      if (std::chrono::steady_clock::now() >= deadline)
        throw std::runtime_error("The isolated timelines did not advance");
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  };
  wait([&] { return pump(*primary, 0, kSplit, 8, kFinish) == kSplit - 1; });
  if (primary_texture.published() <= primary_video || presentation_texture.published() != idle_video ||
      audio_frames[0] == 0 || audio_frames[1] != idle_audio)
    throw std::runtime_error("The primary did not publish audio and video independently of the idle core");
  if (!presentation->StartNetplay()) throw std::runtime_error("Could not start the presentation timeline");
  wait([&] {
    const auto first = pump(*primary, 0, kFinish, 8, kFinish);
    const auto second = pump(*presentation, 1, kSplit, 256, kFinish);
    return first == kFinish - 1 && second == kSplit - 1;
  });
  primary.reset();
  const auto continued_video = presentation_texture.published();
  const auto continued_audio = audio_frames[1].load();
  wait([&] {
    return pump(*presentation, 1, kFinish, 256, kFinish) == kFinish - 1 &&
           presentation->rollback_audio_drained() == kFinish - 1;
  });
  presentation->Stop();
  presentation->Join();
  if (presentation_texture.published() <= continued_video || audio_frames[1] <= continued_audio ||
      !std::get<std::string>(presentation->Status().at(Value("error"))).empty())
    throw std::runtime_error("The presentation core lost its texture or callback owner");
  std::cout << "Two isolated PS1 cores each confirmed " << kFinish
            << " frames in one process with separate video and audio callbacks." << std::endl;

  presentation.reset();
  sent[0] = 0;
  auto source = make(primary_texture, argv[1], Slot::kPrimary, 8, kSplit);
  ready(*source);
  if (!source->StartNetplay()) throw std::runtime_error("Could not start the checkpoint source");
  wait([&] { return pump(*source, 0, kSplit, 8, kSplit) == kSplit - 1; });
  auto capture = source->CapturePresentation();
  if (!capture.valid() || capture.wait_for(std::chrono::seconds(5)) != std::future_status::ready)
    throw std::runtime_error("Timed out capturing the presentation state");
  auto snapshot = capture.get();
  if (!snapshot || snapshot->frame != kSplit)
    throw std::runtime_error("The primary captured the wrong presentation frame");
  auto spare = make(presentation_texture, argv[6], Slot::kPresentation, 256, kFinish);
  ready(*spare);
  const auto spare_audio = audio_frames[1].load();
  const auto spare_video = presentation_texture.published();
  const Ps1Ports ports{{{8, {}}, {}}};
  if (spare->RenderPresentation(std::nullopt, {ports}).valid())
    throw std::runtime_error("The presentation core advanced before receiving its initial checkpoint");
  const auto wait_render = [](std::future<bool> render) {
    if (!render.valid() || render.wait_for(std::chrono::seconds(5)) != std::future_status::ready || !render.get())
      throw std::runtime_error("The presentation core did not render independently of the network timeline");
  };
  wait_render(spare->RenderPresentation(std::move(snapshot), {ports}));
  wait_render(spare->RenderPresentation(std::nullopt, {ports}));
  if (spare->StartNetplay() || spare->SyncNetplay({{0, {}}}, std::nullopt))
    throw std::runtime_error("The presentation core accepted network input");
  if (presentation_texture.published() <= spare_video || audio_frames[1] != spare_audio)
    throw std::runtime_error("The restored core did not produce video alone");
  const auto fingerprint = [](const char* path) {
    const auto dll = GetModuleHandleW(std::filesystem::u8path(path).c_str());
    if (!dll) throw std::runtime_error("The test core module was not loaded");
    const auto* ram = static_cast<const uint8_t*>(Symbol<void* (*)(unsigned)>(dll, "retro_get_memory_data")(2));
    const auto size = Symbol<size_t (*)(unsigned)>(dll, "retro_get_memory_size")(2);
    if (!ram || !size) throw std::runtime_error("The test core did not expose RAM");
    return NetplayFingerprint(ram, size);
  };
  const auto restored = fingerprint(argv[6]);
  source.reset();
  sent[0] = 0;
  auto control = make(primary_texture, argv[1], Slot::kPrimary, 8, kSplit + 2);
  ready(*control);
  if (!control->StartNetplay()) throw std::runtime_error("Could not start the uninterrupted control");
  wait([&] { return pump(*control, 0, kSplit + 2, 8, kSplit + 2) == kSplit + 1; });
  if (restored != fingerprint(argv[1]))
    throw std::runtime_error("Presentation RAM diverged from uninterrupted emulation");
  std::cout << "Same-binary restore advanced two frames, published silent video and matched uninterrupted CTR RAM."
            << std::endl;
}

bool VerifyAudioQueueTiming() {
  using Clock = std::chrono::steady_clock;
  const auto start = Clock::now();
  Clock::time_point refilled{};
  std::promise<void> initial;
  std::promise<bool> completed;
  auto initial_result = initial.get_future();
  auto result = completed.get_future();
  uint32_t expected = 0;
  bool matched = true;
  ConfirmedPcmPlayout playout(48000, [&](uint32_t frame, const int16_t* pcm, size_t frames) {
    const auto elapsed = Clock::now() - start;
    matched &= frame == expected && frames == 480 && pcm[0] == static_cast<int16_t>(frame + 10);
    if (frame < 2) {
      matched &= elapsed >= std::chrono::milliseconds(120 + frame * 10);
    } else {
      matched &= Clock::now() - refilled >= std::chrono::milliseconds(120);
    }
    if (++expected == 2) initial.set_value();
    if (expected == 3) completed.set_value(matched);
  });
  std::array<int16_t, 960> pcm{};
  pcm[0] = 10;
  playout.Submit(0, pcm.data(), pcm.size());
  pcm[0] = 11;
  playout.Submit(1, pcm.data(), pcm.size());
  if (initial_result.wait_for(std::chrono::seconds(2)) != std::future_status::ready) return false;
  std::this_thread::sleep_for(std::chrono::milliseconds(40));
  pcm[0] = 12;
  refilled = Clock::now();
  playout.Submit(2, pcm.data(), pcm.size());
  return result.wait_for(std::chrono::seconds(2)) == std::future_status::ready && result.get() &&
         playout.underruns() == 1;
}

int main(int argc, char** argv) {
  if (argc == 2 && std::string_view(argv[1]) == "audio-queue-test") {
    if (!VerifyAudioQueueTiming()) return 10;
    std::cout << "Confirmed PCM preserved order, 10 ms sample deadlines, and both 120 ms reserves." << std::endl;
    return 0;
  }
  if (argc < 5 || argc > 8) return 2;
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
  ProbeTexture texture;
  if (argc == 7 && std::string_view(argv[5]) == "isolated-cores") {
    try {
      VerifyIsolatedCores(argv);
      return 0;
    } catch (const std::exception& error) {
      std::cerr << error.what() << std::endl;
      return 9;
    }
  }
  if (argc == 7 && std::string_view(argv[5]) == "replace") {
    try {
      return VerifyReplacement(texture, argv);
    } catch (const std::exception& failure) {
      std::cerr << failure.what() << '\n';
      return 8;
    }
  }
  const auto seat = std::stoul(argv[4]);
  const auto primary_core_path = std::filesystem::u8path(argv[1]);
  const bool local_staging = argc == 6 && std::string_view(argv[5]) == "local";
  const bool recompiler = argc == 6 && std::string_view(argv[5]) == "recompiler";
  const bool dual = argc >= 7 && std::string_view(argv[5]) == "rollback-dual";
  const bool rollback = dual || (argc >= 6 && std::string_view(argv[5]) == "rollback");
  const bool audio_control = argc == 6 && std::string_view(argv[5]) == "audio-control";
  if (argc == 6 && !local_staging && !recompiler && !rollback && !audio_control) return 2;
  const bool ordinary = argc == 7 && std::string_view(argv[5]) == "ordinary";
  if (argc == 7 && !ordinary && !rollback) return 2;
  if (argc == 8 && !dual) return 2;
  std::vector<uint16_t> trace;
  if (rollback && argc == (dual ? 8 : 7)) {
    std::ifstream input(std::filesystem::u8path(argv[dual ? 7 : 6]));
    unsigned value;
    while (input >> value) {
      if (value > UINT16_MAX || trace.size() >= 60000) return 2;
      trace.push_back(static_cast<uint16_t>(value));
    }
    if (input.bad() || !input.eof() || trace.size() < 2 || trace[0] || trace[1]) return 2;
  }
  const auto bios_directory = std::filesystem::u8path(argv[3]).parent_path().u8string();
  std::mutex audio_mutex;
  size_t audio_frames = 0;
  uint64_t audio_hash = 14695981039346656037ull;
  std::chrono::steady_clock::time_point last_audio{};
  int64_t max_audio_gap_us = 0;
  RetroCoreSession::AudioSink audio_sink;
  if (rollback || audio_control) {
    audio_sink = [&](const int16_t* samples, size_t frames) {
      std::lock_guard<std::mutex> lock(audio_mutex);
      const auto now = std::chrono::steady_clock::now();
      if (last_audio != std::chrono::steady_clock::time_point{})
        max_audio_gap_us = std::max(max_audio_gap_us,
            std::chrono::duration_cast<std::chrono::microseconds>(now - last_audio).count());
      last_audio = now;
      audio_frames += frames;
      for (size_t i = 0; i < frames * 2; ++i) {
        audio_hash ^= static_cast<uint16_t>(samples[i]);
        audio_hash *= 1099511628211ull;
      }
    };
  }
  ProbeTexture spare_texture;
  RetroCoreSession session(&texture, argv[1], argv[2], ordinary ? bios_directory : "",
                           ordinary ? argv[6] : "", "", {},
                           ordinary ? std::nullopt : std::optional<unsigned>(seat), argv[3], local_staging,
                           std::nullopt, std::nullopt, {},
                           recompiler ? Ps1MatchCpu::kRecompiler : Ps1MatchCpu::kCachedInterpreter, {}, rollback,
                           std::move(audio_sink), std::move(trace));
  if (dual && !session.AttachPresentationCore(std::make_unique<RetroCoreSession>(
      &spare_texture, argv[6], argv[2], "", "", "", std::map<std::string, std::string>{}, seat, argv[3],
      false, std::nullopt, std::nullopt, std::vector<std::string>{}, Ps1MatchCpu::kCachedInterpreter,
      nullptr, true, [](const int16_t*, size_t) {}, std::vector<uint16_t>{},
      RetroCoreSession::CallbackSlot::kPresentation))) return 3;
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
    if (dual && command == "presentation-steps") {
      std::cout << session.presentation_steps() << ' ' << session.presentation_frames() << ' '
                << session.peak_prediction_depth() << std::endl;
      continue;
    }
    if (rollback && command == "pacing") {
      const auto [blocked, wait_us, late_wakes, wake_us] = session.trace_pacing();
      std::cout << blocked << ' ' << wait_us << ' ' << late_wakes << ' ' << wake_us << std::endl;
      continue;
    }
    if ((rollback || audio_control) && command == "audio") {
      std::lock_guard<std::mutex> lock(audio_mutex);
      std::cout << audio_frames << ' ' << audio_hash << std::endl;
      continue;
    }
    if (rollback && command == "presentation") {
      const auto [max_video_gap, long_video_gaps] = texture.presentation_gaps();
      std::lock_guard<std::mutex> lock(audio_mutex);
      std::cout << texture.published() << ' ' << max_video_gap << ' ' << long_video_gaps << ' '
                << max_audio_gap_us << ' ' << session.trace_max_work_us() << ' '
                << session.trace_work_overruns() << std::endl;
      continue;
    }
    if (rollback && command == "audio-drained") {
      std::cout << session.rollback_audio_drained() << std::endl;
      continue;
    }
    if (dual && command == "audio-pacing") {
      const auto [underruns, queue_peak] = session.trace_audio_pacing();
      std::cout << underruns << ' ' << queue_peak << std::endl;
      continue;
    }
    if (rollback && command == "confirmed") {
      const auto state = session.SyncNetplay({}, std::nullopt);
      if (!state) return 6;
      std::cout << IntegerValue(state->at(Value("confirmedFrame"))).value_or(-1) << std::endl;
      continue;
    }
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
      const auto dll = GetModuleHandleW(primary_core_path.c_str());
      if (!dll) return 7;
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
      std::string digest_text;
      std::string path;
      if (!(std::cin >> digest_text >> std::quoted(path))) return 7;
      std::array<uint8_t, 32> digest{};
      const auto parse_byte = [](const char* first, const char* last, int base, uint8_t& byte) {
        unsigned value = 0;
        const auto parsed = std::from_chars(first, last, value, base);
        if (parsed.ec != std::errc{} || parsed.ptr != last || value > UINT8_MAX) return false;
        byte = static_cast<uint8_t>(value);
        return true;
      };
      if (digest_text.size() == digest.size() * 2) {
        for (size_t i = 0; i < digest.size(); ++i) {
          const auto* first = digest_text.data() + i * 2;
          if (!parse_byte(first, first + 2, 16, digest[i])) return 7;
        }
      } else if (!parse_byte(digest_text.data(), digest_text.data() + digest_text.size(), 10, digest[0])) {
        return 7;
      }
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
      const auto dll = GetModuleHandleW(primary_core_path.c_str());
      if (!dll) return 7;
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
      const auto dll = GetModuleHandleW(primary_core_path.c_str());
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
