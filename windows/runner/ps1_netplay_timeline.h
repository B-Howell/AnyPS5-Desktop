#ifndef RUNNER_PS1_NETPLAY_TIMELINE_H_
#define RUNNER_PS1_NETPLAY_TIMELINE_H_

#include <algorithm>
#include <array>
#include <cstdint>
#include <map>
#include <optional>
#include <stdexcept>
#include <vector>

namespace ps1_netplay {

struct PadInput {
  uint16_t buttons = 0;
  std::array<int16_t, 4> axes{};

  bool operator==(const PadInput& other) const {
    return buttons == other.buttons && axes == other.axes;
  }
};

struct FrameInput {
  uint32_t frame;
  PadInput input;

  bool operator==(const FrameInput& other) const {
    return frame == other.frame && input == other.input;
  }
};

// Confirmed-input control. The emulator worker exclusively prepares/commits
// frames; callers serialize exchanges with it. A waiting frame never calls
// retro_run and cannot publish speculative audio, video, or save writes.
class Timeline {
 public:
  static constexpr uint32_t kDelay = 2;
  static constexpr uint32_t kHistory = 64;
  static constexpr uint32_t kMaxFrame = 0xfffffffe;
  static constexpr uint32_t kMaxPacket = 8;

  explicit Timeline(unsigned seat) : seat_(seat) {
    if (seat > 1) throw std::invalid_argument("Invalid PS1 netplay seat");
    for (uint32_t frame = 0; frame < kDelay; ++frame) local_.emplace(frame, PadInput{});
  }

  void Start() { started_ = true; }
  bool Hold() {
    if (prepared_) return false;
    started_ = false;
    return true;
  }
  void Reset() { *this = Timeline(seat_); }
  uint32_t frame() const { return frame_; }
  std::optional<uint32_t> confirmed() const {
    return frame_ ? std::optional<uint32_t>(frame_ - 1) : std::nullopt;
  }
  std::optional<uint32_t> received() const { return received_; }
  bool waiting() const {
    return !started_ || (!prepared_ && (remote_.find(frame_) == remote_.end() || !CanSample()));
  }

  bool Receive(const std::vector<FrameInput>& samples, std::optional<uint32_t> acknowledged) {
    if (acknowledged && *acknowledged > local_.rbegin()->first) return false;
    const auto oldest = frame_ > kHistory ? frame_ - kHistory : 0;
    std::map<uint32_t, PadInput> incoming;
    for (const auto& sample : samples) {
      if (sample.frame > kMaxFrame || (sample.frame > frame_ && sample.frame - frame_ > kHistory)) return false;
      if (sample.frame < oldest) continue;
      const auto existing = remote_.find(sample.frame);
      if (existing != remote_.end()) {
        if (!(existing->second == sample.input)) return false;
        continue;
      }
      const auto inserted = incoming.emplace(sample.frame, sample.input);
      if (!(inserted.first->second == sample.input)) return false;
    }
    if (acknowledged && (!acknowledged_ || *acknowledged > *acknowledged_)) acknowledged_ = acknowledged;
    remote_.merge(incoming);
    auto next = received_ ? *received_ + 1 : 0;
    while (remote_.count(next)) received_ = next++;
    Prune();
    return true;
  }

  bool Prepare(const PadInput& local, std::array<PadInput, 2>& ports) {
    if (!started_ || prepared_ || !CanSample()) return false;
    local_.emplace(frame_ + kDelay, local);
    const auto other = remote_.find(frame_);
    if (other == remote_.end()) return false;
    ports[seat_] = local_.at(frame_);
    ports[1 - seat_] = other->second;
    prepared_ = true;
    return true;
  }

  void Commit() {
    if (!prepared_) throw std::logic_error("PS1 netplay frame was not prepared");
    ++frame_;
    prepared_ = false;
    Prune();
  }

  std::vector<FrameInput> LocalPacket() const {
    const auto latest = local_.rbegin()->first;
    const auto unacknowledged = acknowledged_ ? *acknowledged_ + 1 : 0;
    const auto overlap = latest >= kMaxPacket - 1 ? latest - (kMaxPacket - 1) : 0;
    const auto first = std::min(unacknowledged, overlap);
    std::vector<FrameInput> samples;
    samples.reserve(kMaxPacket);
    for (auto it = local_.lower_bound(first); it != local_.end() && samples.size() < kMaxPacket; ++it)
      samples.push_back({it->first, it->second});
    return samples;
  }

 private:
  bool CanSample() const {
    if (frame_ > kMaxFrame - kDelay) return false;
    const auto unacknowledged = acknowledged_ ? *acknowledged_ + 1 : 0;
    const auto target = frame_ + kDelay;
    return target < unacknowledged || target - unacknowledged < kHistory;
  }

  void Prune() {
    const auto oldest_remote = frame_ > kHistory ? frame_ - kHistory : 0;
    remote_.erase(remote_.begin(), remote_.lower_bound(oldest_remote));
    if (acknowledged_) {
      const auto overlap = *acknowledged_ >= kMaxPacket - 1 ? *acknowledged_ - (kMaxPacket - 1) : 0;
      const auto oldest_local = std::min(frame_, overlap);
      local_.erase(local_.begin(), local_.lower_bound(oldest_local));
    }
  }

  unsigned seat_;
  bool started_ = false;
  bool prepared_ = false;
  uint32_t frame_ = 0;
  std::optional<uint32_t> acknowledged_;
  std::optional<uint32_t> received_;
  std::map<uint32_t, PadInput> local_;
  std::map<uint32_t, PadInput> remote_;
};

}  // namespace ps1_netplay

#endif  // RUNNER_PS1_NETPLAY_TIMELINE_H_
