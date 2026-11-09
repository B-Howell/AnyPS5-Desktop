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
