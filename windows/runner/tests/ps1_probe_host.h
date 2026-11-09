#pragma once

#include <windows.h>
#include <mmsystem.h>

static MMRESULT WINAPI SilentWaveOutWrite(HWAVEOUT, LPWAVEHDR header, UINT) {
  header->dwFlags = (header->dwFlags & ~WHDR_INQUEUE) | WHDR_DONE;
  return MMSYSERR_NOERROR;
}

#define waveOutWrite SilentWaveOutWrite
#include "../retro_core_host.cpp"
#undef waveOutWrite

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
    {
      std::lock_guard<std::mutex> lock(presentation_mutex_);
      const auto now = std::chrono::steady_clock::now();
      if (last_frame_ != decltype(last_frame_){}) {
        const auto gap = std::chrono::duration_cast<std::chrono::microseconds>(now - last_frame_).count();
        max_gap_us_ = std::max(max_gap_us_, gap);
        if (gap > 33334) ++long_gaps_;
      }
      last_frame_ = now;
    }
    ++published_;
    return true;
  }

  void UnregisterTexture(int64_t, std::function<void()> complete) override {
    if (complete) complete();
  }

  bool UnregisterTexture(int64_t) override { return true; }
  uint64_t published() const { return published_; }
  std::pair<int64_t, uint64_t> presentation_gaps() {
    std::lock_guard<std::mutex> lock(presentation_mutex_);
    return {max_gap_us_, long_gaps_};
  }

 private:
  flutter::TextureVariant* texture_ = nullptr;
  int64_t registered_ = 0;
  std::atomic<uint64_t> published_{0};
  std::mutex presentation_mutex_;
  std::chrono::steady_clock::time_point last_frame_{};
  int64_t max_gap_us_ = 0;
  uint64_t long_gaps_ = 0;
};
