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

inline ps1_checkpoint::Snapshot ReadMatchCheckpoint(FlValue* args) {
  auto* frame = Field(args, "frame");
  if (!frame || fl_value_get_type(frame) != FL_VALUE_TYPE_INT || fl_value_get_int(frame) < 0 ||
      fl_value_get_int(frame) > ps1_netplay::Timeline::kMaxFrame)
    throw std::runtime_error("Invalid portable checkpoint frame.");
  auto* state = Field(args, "state");
  if (!state || fl_value_get_type(state) != FL_VALUE_TYPE_UINT8_LIST || !fl_value_get_length(state) ||
      fl_value_get_length(state) > ps1_checkpoint::kMaximumBytes)
    throw std::runtime_error("Invalid portable checkpoint size.");
  const auto* bytes = fl_value_get_uint8_list(state);
  return {static_cast<uint32_t>(fl_value_get_int(frame)), {bytes, bytes + fl_value_get_length(state)}};
}

inline std::optional<Ps1MatchConfig> ReadPs1Match(FlValue* args) {
  for (const auto* flag : {"ps1NetplayCpu", "ps1PresentationCore", "ps1LocalStaging", "ps3Online"}) {
    if (Field(args, flag)) throw std::runtime_error("This online worker is not yet available on Linux");
  }
  auto* seat = Field(args, "ps1NetplaySeat");
  auto* bios = Field(args, "ps1NetplayBios");
  auto* dualshock = Field(args, "ps1NetplayDualShock");
  if (!seat && !bios && !dualshock) return std::nullopt;
  if (!seat || fl_value_get_type(seat) != FL_VALUE_TYPE_INT || fl_value_get_int(seat) < 0 ||
      fl_value_get_int(seat) > 1 || !bios || fl_value_get_type(bios) != FL_VALUE_TYPE_STRING ||
      (dualshock && fl_value_get_type(dualshock) != FL_VALUE_TYPE_BOOL))
    throw std::runtime_error("Invalid synchronized PS1 seat or BIOS.");
  return Ps1MatchConfig{static_cast<unsigned>(fl_value_get_int(seat)), fl_value_get_string(bios),
                       dualshock && fl_value_get_bool(dualshock)};
}

struct MatchExchange {
  std::vector<ps1_netplay::FrameInput> remote;
  std::optional<uint32_t> acknowledged;
};

inline MatchExchange ReadMatchExchange(FlValue* args) {
  constexpr auto max_frame = ps1_netplay::Timeline::kMaxFrame;
  const auto integer = [](FlValue* value, int64_t min, int64_t max) {
    if (!value || fl_value_get_type(value) != FL_VALUE_TYPE_INT)
      throw std::runtime_error("Invalid synchronized PS1 input.");
    const auto number = fl_value_get_int(value);
    if (number < min || number > max) throw std::runtime_error("Invalid synchronized PS1 input.");
    return number;
  };
  MatchExchange exchange;
  auto* ack = Field(args, "acknowledgedFrame");
  if (ack && fl_value_get_type(ack) != FL_VALUE_TYPE_NULL)
    exchange.acknowledged = static_cast<uint32_t>(integer(ack, 0, max_frame));
  auto* frames = Field(args, "remote");
  if (!frames || fl_value_get_type(frames) != FL_VALUE_TYPE_LIST || fl_value_get_length(frames) > 32)
    throw std::runtime_error("Invalid synchronized PS1 input batch.");
  for (size_t i = 0; i < fl_value_get_length(frames); ++i) {
    auto* sample = fl_value_get_list_value(frames, i);
    if (fl_value_get_type(sample) != FL_VALUE_TYPE_LIST || fl_value_get_length(sample) != 6)
      throw std::runtime_error("Invalid synchronized PS1 frame.");
    ps1_netplay::FrameInput frame{};
    frame.frame = static_cast<uint32_t>(integer(fl_value_get_list_value(sample, 0), 0, max_frame));
    frame.input.buttons = static_cast<uint16_t>(integer(fl_value_get_list_value(sample, 1), 0, UINT16_MAX));
    for (size_t axis = 0; axis < frame.input.axes.size(); ++axis)
      frame.input.axes[axis] = static_cast<int16_t>(integer(fl_value_get_list_value(sample, axis + 2),
                                                          INT16_MIN, INT16_MAX));
    exchange.remote.push_back(frame);
  }
  return exchange;
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
