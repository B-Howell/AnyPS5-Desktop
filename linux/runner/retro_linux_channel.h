#ifndef ANYPS5_RETRO_LINUX_CHANNEL_H_
#define ANYPS5_RETRO_LINUX_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

#include <cstdint>
#include <algorithm>
#include <optional>
#include <stdexcept>

#include "retro_session.h"

namespace anyps5::retro::linux_channel {

inline FlValue* Field(FlValue* map, const char* key) {
  return map && fl_value_get_type(map) == FL_VALUE_TYPE_MAP ? fl_value_lookup_string(map, key) : nullptr;
}

// A null payload is valid; an absent optional means the command is stale.
inline std::optional<FlValue*> OwnedArguments(FlValue* args, int64_t active_session) {
  auto* owner = Field(args, "owner");
  if (!owner || fl_value_get_type(owner) != FL_VALUE_TYPE_INT || active_session <= 0 ||
      fl_value_get_int(owner) != active_session) return std::nullopt;
  return Field(args, "value");
}

inline std::optional<int64_t> ReadCheckpointSource(FlValue* args, int64_t texture_id) {
  auto* texture = Field(args, "texture");
  auto* source = Field(args, "source");
  if (!texture || fl_value_get_type(texture) != FL_VALUE_TYPE_INT || fl_value_get_int(texture) != texture_id ||
      !source || fl_value_get_type(source) != FL_VALUE_TYPE_INT || fl_value_get_int(source) <= 0) return std::nullopt;
  return fl_value_get_int(source);
}

inline ps1_checkpoint::Digest ReadCheckpointDigest(FlValue* args) {
  auto* digest = Field(args, "discHash");
  if (!digest || fl_value_get_type(digest) != FL_VALUE_TYPE_UINT8_LIST || fl_value_get_length(digest) != 32)
    throw std::runtime_error("Expected a 32-byte verified disc digest");
  ps1_checkpoint::Digest result;
  std::copy_n(fl_value_get_uint8_list(digest), result.size(), result.begin());
  return result;
}

inline void ValidateOnlineStart(FlValue* args) {
  // Until the complete worker contracts are ported, never silently downgrade
  // a requested online game into an ordinary session.
  for (const auto* flag : {"ps1NetplaySeat", "ps1NetplayBios", "ps1NetplayDualShock",
                           "ps1NetplayCpu", "ps1PresentationCore", "ps1LocalStaging", "ps3Online"}) {
    if (Field(args, flag)) throw std::runtime_error("This online worker is not yet available on Linux");
  }
}

inline std::optional<LanFrames> ReadLanFrames(FlValue* args, int64_t texture_id) {
  auto* texture = Field(args, "texture");
  if (!texture || fl_value_get_type(texture) != FL_VALUE_TYPE_INT ||
      fl_value_get_int(texture) != texture_id) return std::nullopt;
  auto* frames = Field(args, "frames");
  if (!frames || fl_value_get_type(frames) != FL_VALUE_TYPE_LIST || fl_value_get_length(frames) > 16)
    throw std::runtime_error("Expected a bounded PS2 LAN frame batch");
  LanFrames input;
  for (size_t index = 0; index < fl_value_get_length(frames); ++index) {
    auto* frame = fl_value_get_list_value(frames, index);
    if (fl_value_get_type(frame) != FL_VALUE_TYPE_UINT8_LIST ||
        fl_value_get_length(frame) < 14 || fl_value_get_length(frame) > 1514)
      throw std::runtime_error("Invalid PS2 Ethernet frame");
    const auto* bytes = fl_value_get_uint8_list(frame);
    input.emplace_back(bytes, bytes + fl_value_get_length(frame));
  }
  return input;
}

}  // namespace anyps5::retro::linux_channel

#endif  // ANYPS5_RETRO_LINUX_CHANNEL_H_
