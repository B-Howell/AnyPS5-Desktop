#ifndef RUNNER_RETRO_CORE_HOST_H_
#define RUNNER_RETRO_CORE_HOST_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/texture_registrar.h>

#include <cstdint>
#include <memory>
#include <optional>

class RetroCoreSession;
struct Ps1OrdinaryRecovery;

class RetroCoreHost {
 public:
  RetroCoreHost(flutter::BinaryMessenger* messenger, flutter::TextureRegistrar* textures);
  ~RetroCoreHost();

 private:
  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Release();

  flutter::TextureRegistrar* textures_;
  std::shared_ptr<RetroCoreSession> session_;
  std::shared_ptr<Ps1OrdinaryRecovery> ordinary_recovery_;
  std::optional<int64_t> ps1_return_request_;
  flutter::MethodChannel<flutter::EncodableValue> channel_;
};

#endif  // RUNNER_RETRO_CORE_HOST_H_
