#include "ps1_match.h"
#include "retro_session.h"
#include "retro_test_support.h"

#include <filesystem>
#include <fstream>
#include <iostream>

using namespace anyps5::retro;
using namespace anyps5::retro::test;

namespace {
void CheckSeat(const char* core, const std::filesystem::path& root, unsigned seat,
               const std::string& expected) {
  const std::array<ps1_netplay::PadInput, 2> pads{{{1, {-22, 0, 0, 0}}, {2, {33, 0, 0, 0}}}};
  SessionConfig config{core, "test.cue", root.u8string(), root.u8string(), "",
                       {{"swanstation_CDROM_ReadThread", "true"}}};
  config.ps1_match = Ps1MatchConfig{seat, (root / "bios.bin").u8string(), true};
  Session match(std::move(config), std::make_unique<TestVideo>(), std::make_unique<TestAudio>(), [] {});
  Check(!match.StartNetplay(), "Match started before the core was ready");
  match.Start();
  WaitFor([&] { return match.Status().netplay_ready || match.ended(); }, "Match worker did not become ready");
  Check(match.Status().netplay_ready, match.Status().error.c_str());
  Check(match.Status().options.at("swanstation_CDROM_ReadThread").active_value == "false",
        "An offline option override reached the match");
  Check(!match.AcquireFrame() && match.Status().telemetry.steps == 0, "Core advanced before match start");
  match.SetInput(pads[seat].buttons, pads[seat].axes);
  Check(match.StartNetplay() && match.StartNetplay(), "Match start was not idempotent");
  Check(match.SyncNetplay({{0, {}}}, {}).has_value(), "First remote frame rejected");
  WaitFor([&] {
    const auto tick = match.SyncNetplay({}, {});
    return tick && tick->frame == 1 && tick->waiting;
  }, "Worker did not stop at the missing remote frame");
  Check(!match.SyncNetplay({{0, pads[1 - seat]}}, {}), "Conflicting input rewrote a confirmed frame");

  uint32_t next_remote = 1;
  std::optional<uint32_t> ack;
  Ps1MatchTick result{};
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(8);
  while (result.frame < 120 && std::chrono::steady_clock::now() < deadline) {
    std::vector<ps1_netplay::FrameInput> batch;
    while (next_remote < 120 && next_remote <= result.frame + 8) {
      batch.push_back({next_remote, next_remote < 2 ? ps1_netplay::PadInput{} : pads[1 - seat]});
      ++next_remote;
    }
    const auto update = match.SyncNetplay(batch, ack);
    Check(update.has_value(), "Match exchange rejected valid frames");
    result = *update;
    if (!result.local.empty()) ack = result.local.back().frame;
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  Check(result.frame == 120 && result.confirmed == 119 && result.received == 119,
        "Worker did not finish the confirmed trace");
  Check(result.fingerprints.size() == 1 && result.fingerprints[0] == std::make_pair(119u, expected),
        "Wrong controller routing or RAM fingerprint");
  Check(match.AcquireFrame() != nullptr, "Match did not present a frame");
  Check(!match.Status().checkpoint_source, "Match exposed ordinary recovery");
  Check(!match.SetOption("swanstation_CPU_ExecutionMode", "Recompiler"), "Match accepted a profile change");
  match.Stop(); match.Join();
  Check(!match.SyncNetplay({}, {}), "Stopped match accepted network input");
  Check(!std::filesystem::exists(root / "test.srm"), "Match wrote to the ordinary save directory");
}
}  // namespace

int main(int argc, char** argv) {
  std::filesystem::path root;
  try {
    Check(argc == 2, "Pass the PS1 fixture");
    root = std::filesystem::temp_directory_path() /
        ("anyps5-ps1-match-test-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    Check(std::filesystem::create_directory(root), "Could not create match test directory");
    {
      std::ofstream bios(root / "bios.bin", std::ios::binary);
      bios.seekp(512 * 1024 - 1);
      bios.put(0);
      Check(bios.good(), "Could not write the synthetic firmware fixture");
    }
#ifndef _WIN32
    {
      const Ps1MatchStorage storage((root / "bios.bin").u8string());
      const auto permissions = std::filesystem::status(storage.content()).permissions();
      Check((permissions & (std::filesystem::perms::group_all | std::filesystem::perms::others_all)) ==
                std::filesystem::perms::none,
            "Match firmware directory was accessible to other users");
    }
#endif
    std::vector<uint8_t> ram(2 * 1024 * 1024);
    ram[0] = 1;
    ram[1] = static_cast<uint8_t>(-22);
    ram[2] = 2;
    ram[3] = 33;
    const auto expected = NetplayFingerprint(ram.data(), ram.size());
    CheckSeat(argv[1], root, 0, expected);
    CheckSeat(argv[1], root, 1, expected);
    std::filesystem::remove_all(root);
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    if (!root.empty()) std::filesystem::remove_all(root);
    return 1;
  }
}
