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
    fl_value_set_string_take(offline, "ps2LanMac", fl_value_new_uint8_list(packet.data(), 6));
    Check(!ReadPs1Match(offline), "PS2 request became a PS1 match");
    for (const auto* flag : {"ps1NetplaySeat", "ps1NetplayBios", "ps1NetplayDualShock", "ps1NetplayCpu",
                             "ps1PresentationCore", "ps1LocalStaging", "ps3Online"}) {
      g_autoptr(FlValue) unsupported = fl_value_new_map();
      fl_value_set_string_take(unsupported, flag, fl_value_new_null());
      MustReject([&] { ReadPs1Match(unsupported); });
    }
    fl_value_set_string_take(offline, "ps1NetplaySeat", fl_value_new_int(1));
    fl_value_set_string_take(offline, "ps1NetplayBios", fl_value_new_string("/test/bios.bin"));
    Check(ReadPs1Match(offline)->seat == 1, "PS1 seat changed at the channel");
    fl_value_set_string_take(offline, "ps1LocalStaging", fl_value_new_bool(true));
    Check(ReadPs1Match(offline)->local_staging, "PS1 staging flag changed at the channel");
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
