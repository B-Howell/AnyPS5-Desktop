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

    g_autoptr(FlValue) offline = fl_value_new_map();
    ValidateOnlineStart(offline);
    fl_value_set_string_take(offline, "ps2LanMac", fl_value_new_uint8_list(packet.data(), 6));
    ValidateOnlineStart(offline);
    for (const auto* flag : {"ps1NetplaySeat", "ps1NetplayBios", "ps1NetplayDualShock", "ps1NetplayCpu",
                             "ps1PresentationCore", "ps1LocalStaging", "ps3Online"}) {
      g_autoptr(FlValue) unsupported = fl_value_new_map();
      fl_value_set_string_take(unsupported, flag, fl_value_new_null());
      MustReject([&] { ValidateOnlineStart(unsupported); });
    }
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
