#include "../retro_linux_channel.h"
#include "retro_test_support.h"

#include <iostream>

using namespace anyps5::retro;
using namespace anyps5::retro::linux_channel;
using anyps5::retro::test::Check;

template <typename Function>
void MustReject(Function function) {
  bool rejected = false;
  try { function(); } catch (const std::runtime_error&) { rejected = true; }
  Check(rejected, "Malformed or unsupported online request was accepted");
}

int main() {
  try {
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "owner", fl_value_new_int(1));
    fl_value_set_string_take(args, "value", fl_value_new_null());
    Check(OwnedArguments(args, 1).has_value(), "Valid owner with null payload was rejected");
    Check(!OwnedArguments(args, 0) && !OwnedArguments(args, 2), "Stale owner reached a reused texture");
    fl_value_set_string_take(args, "owner", fl_value_new_string("1"));
    Check(!OwnedArguments(args, 1) && !OwnedArguments(nullptr, 1), "Invalid owner was coerced");

    g_autoptr(FlValue) request = fl_value_new_map();
    fl_value_set_string_take(request, "texture", fl_value_new_int(123));
    auto* frames = fl_value_new_list();
    fl_value_set_string_take(request, "frames", frames);
    Check(ReadLanFrames(request, 123)->empty(), "Empty poll was rejected");
    Check(!ReadLanFrames(request, 124), "Wrong texture accepted traffic");
    const std::vector<uint8_t> packet(64, 42);
    fl_value_append_take(frames, fl_value_new_uint8_list(packet.data(), packet.size()));
    Check(ReadLanFrames(request, 123)->front() == packet, "Typed packet bytes changed");
    fl_value_append_take(frames, fl_value_new_string("bad"));
    MustReject([&] { ReadLanFrames(request, 123); });
    for (const size_t size : {13, 1515}) {
      const std::vector<uint8_t> invalid(size);
      auto* batch = fl_value_new_list();
      fl_value_append_take(batch, fl_value_new_uint8_list(invalid.data(), invalid.size()));
      fl_value_set_string_take(request, "frames", batch);
      MustReject([&] { ReadLanFrames(request, 123); });
    }
    auto* oversized = fl_value_new_list();
    for (int i = 0; i < 17; ++i)
      fl_value_append_take(oversized, fl_value_new_uint8_list(packet.data(), packet.size()));
    fl_value_set_string_take(request, "frames", oversized);
    MustReject([&] { ReadLanFrames(request, 123); });
    fl_value_set_string_take(request, "frames", fl_value_new_null());
    MustReject([&] { ReadLanFrames(request, 123); });

    fl_value_set_string_take(request, "source", fl_value_new_int(9));
    Check(ReadCheckpointSource(request, 123) == 9 && !ReadCheckpointSource(request, 124),
          "Checkpoint source ignored surface ownership");
    fl_value_set_string_take(request, "source", fl_value_new_int(0));
    Check(!ReadCheckpointSource(request, 123), "Invalid checkpoint source was accepted");
    MustReject([&] { ReadCheckpointDigest(request); });
    fl_value_set_string_take(request, "discHash", fl_value_new_uint8_list(packet.data(), 31));
    MustReject([&] { ReadCheckpointDigest(request); });
    fl_value_set_string_take(request, "discHash", fl_value_new_uint8_list(packet.data(), 32));
    Check(ReadCheckpointDigest(request).front() == 42, "Checkpoint digest changed in channel decoding");
    MustReject([&] { ReadMatchCheckpoint(request); });
    fl_value_set_string_take(request, "frame", fl_value_new_int(37));
    MustReject([&] { ReadMatchCheckpoint(request); });
    fl_value_set_string_take(request, "state", fl_value_new_uint8_list(packet.data(), 8));
    const auto imported = ReadMatchCheckpoint(request);
    Check(imported.frame == 37 && imported.state == ps1_checkpoint::Bytes(8, 42),
          "Checkpoint bytes or frame changed in channel decoding");

    g_autoptr(FlValue) offline = fl_value_new_map();
    Check(!ReadPs1Match(offline), "Offline request became a match");
    Check(!ReadPs3Online(offline, Console::kPs3), "Offline request acquired a PS3 online policy");
    g_autoptr(FlValue) online = fl_value_new_map();
    fl_value_set_string_take(online, "ps3Online", fl_value_new_null());
    MustReject([&] { ReadPs3Online(online, Console::kPs3); });
    auto* policy = fl_value_new_map();
    fl_value_set_string_take(online, "ps3Online", policy);
    fl_value_set_string_take(policy, "xfloat", fl_value_new_string("strict"));
    fl_value_set_string_take(policy, "dns", fl_value_new_string("192.0.2.1"));
    fl_value_set_string_take(policy, "upnp", fl_value_new_bool(false));
    auto* identity = fl_value_new_map();
    fl_value_set_string_take(policy, "rpcnIdentity", identity);
    fl_value_set_string_take(identity, "host", fl_value_new_string("fixture.invalid"));
    fl_value_set_string_take(identity, "certificateSha256", fl_value_new_string("certificate"));
    auto* protection = fl_value_new_map();
    fl_value_set_string_take(policy, "patchProtection", protection);
    fl_value_set_string_take(protection, "titleId", fl_value_new_string("TEST00001"));
    fl_value_set_string_take(protection, "updateVersion", fl_value_new_string("01.00"));
    fl_value_set_string_take(protection, "sha256", fl_value_new_string("patch"));
    fl_value_set_string_take(protection, "ppuHash", fl_value_new_string("ppu"));
    auto* patches = fl_value_new_list();
    fl_value_set_string_take(protection, "patches", patches);
    MustReject([&] { ReadPs3Online(online, Console::kPs3); });
    auto* patch = fl_value_new_map();
    fl_value_append_take(patches, patch);
    fl_value_set_string_take(patch, "name", fl_value_new_string("Required patch"));
    fl_value_set_string_take(patch, "option", fl_value_new_string("enabled"));
    fl_value_set_string_take(patch, "writes", fl_value_new_int(2));
    const auto parsed = ReadPs3Online(online, Console::kPs3);
    Check(parsed && parsed->host == "fixture.invalid" && parsed->protection.names.front() == "Required patch" &&
          parsed->protection.writes.front() == 2, "PS3 provider identity or protection changed in decoding");
    MustReject([&] { ReadPs3Online(online, Console::kPs2); });
    fl_value_set_string_take(patch, "writes", fl_value_new_int(4097));
    MustReject([&] { ReadPs3Online(online, Console::kPs3); });
    fl_value_set_string_take(offline, "ps2LanMac", fl_value_new_uint8_list(packet.data(), 6));
    Check(!ReadPs1Match(offline), "PS2 request became a PS1 match");
    for (const auto* flag : {"ps1NetplaySeat", "ps1NetplayBios", "ps1NetplayDualShock", "ps1NetplayCpu",
                             "ps1PresentationCore", "ps1LocalStaging", "ps1NetplayRollback"}) {
      g_autoptr(FlValue) unsupported = fl_value_new_map();
      fl_value_set_string_take(unsupported, flag, fl_value_new_null());
      MustReject([&] { ReadPs1Match(unsupported); });
    }
    fl_value_set_string_take(offline, "ps1NetplaySeat", fl_value_new_int(1));
    fl_value_set_string_take(offline, "ps1NetplayBios", fl_value_new_string("/test/bios.bin"));
    Check(ReadPs1Match(offline)->seat == 1, "PS1 seat changed at the channel");
    fl_value_set_string_take(offline, "ps1LocalStaging", fl_value_new_bool(true));
    Check(ReadPs1Match(offline)->local_staging, "PS1 staging flag changed at the channel");
    Check(!ReadPs1Match(offline)->rollback, "Ordinary netplay opted into rollback");
    fl_value_set_string_take(offline, "ps1NetplayRollback", fl_value_new_bool(true));
    Check(ReadPs1Match(offline)->rollback, "PS1 rollback flag changed at the channel");
    fl_value_set_string_take(offline, "ps1NetplayRollback", fl_value_new_int(1));
    MustReject([&] { ReadPs1Match(offline); });
    auto* remote = fl_value_new_list();
    auto* row = fl_value_new_list();
    for (const int value : {0, 65535, -32768, 32767, 0, 0})
      fl_value_append_take(row, fl_value_new_int(value));
    fl_value_append_take(remote, row);
    fl_value_set_string_take(request, "remote", remote);
    const auto update = ReadMatchExchange(request);
    Check(update.remote.size() == 1 && update.remote[0].input.axes[0] == -32768,
          "Valid PS1 input was changed");
    fl_value_set_string_take(request, "acknowledgedFrame", fl_value_new_int(-1));
    MustReject([&] { ReadMatchExchange(request); });
    MustReject([&] { ReadMatchReplay(request); });
    auto* history = fl_value_new_list();
    auto* ports = fl_value_new_list();
    for (const int buttons : {1, 2}) {
      auto* pad = fl_value_new_list();
      for (const int value : {buttons, -10, 0, 0, 0}) fl_value_append_take(pad, fl_value_new_int(value));
      fl_value_append_take(ports, pad);
    }
    fl_value_append_take(history, ports);
    fl_value_set_string_take(request, "frames", history);
    Check(ReadMatchReplay(request).at(0).at(1).buttons == 2, "Catch-up lost the second controller");
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
