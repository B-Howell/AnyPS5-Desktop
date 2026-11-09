// Runs the Dart probe and the real Windows WebRTC plugin without a Flutter view.
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_webrtc/flutter_web_r_t_c_plugin.h>

#include <chrono>
#include <iostream>
#include <optional>
#include <thread>

int wmain(int argc, wchar_t** argv) {
  if (argc != 2) return 2;
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
  flutter::DartProject project(argv[1]);
  flutter::FlutterEngine engine(project);
  if (!engine.Run()) return 3;
  FlutterWebRTCPluginRegisterWithRegistrar(engine.GetRegistrarForPlugin("FlutterWebRTCPlugin"));

  flutter::MethodChannel<flutter::EncodableValue> report(
      engine.messenger(), "anyps5/ps1_webrtc_probe", &flutter::StandardMethodCodec::GetInstance());
  std::optional<int> status;
  report.SetMethodCallHandler([&](const auto& call, auto result) {
    const auto* message = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
    if ((call.method_name() != "pass" && call.method_name() != "fail") || !message) {
      result->NotImplemented();
      return;
    }
    status = call.method_name() == "pass" ? 0 : 1;
    std::cout << *message << std::endl;
    result->Success();
  });

  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(45);
  while (!status && std::chrono::steady_clock::now() < deadline) {
    MSG message;
    while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessage(&message);
    }
    engine.ProcessMessages();
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  if (!status) std::cerr << "PS1 WebRTC loopback did not finish in 45 seconds.\n";
  report.SetMethodCallHandler(nullptr);
  return status.value_or(4);
}
