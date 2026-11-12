#ifndef RUNNER_RETRO_CORE_HOST_H_
#define RUNNER_RETRO_CORE_HOST_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/texture_registrar.h>

#include <memory>

// The launcher end of the anyps5/retro_core channel. Emulation runs in the
// separate anyps5-retro-host process; this forwards the channel to it and
// shows its frames in a Flutter texture.
class RetroCoreHost {
 public:
  RetroCoreHost(flutter::BinaryMessenger* messenger, flutter::TextureRegistrar* textures);
  ~RetroCoreHost();

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_RETRO_CORE_HOST_H_
