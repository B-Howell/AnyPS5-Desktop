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
  SetPriorityClass(GetCurrentProcess(), IDLE_PRIORITY_CLASS);
  // The process owns this handle until exit so a watchdog failure also stops
  // any native worker that could not respond to its quit command.
  const HANDLE workers = CreateJobObjectW(nullptr, nullptr);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!workers || !SetInformationJobObject(workers, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) ||
      !AssignProcessToJobObject(workers, GetCurrentProcess())) {
    const auto error = GetLastError();
    if (workers) CloseHandle(workers);
    std::cerr << "Could not contain native probe workers. Windows error " << error << '\n';
    return 5;
  }
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

  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(65);
  while (!status && std::chrono::steady_clock::now() < deadline) {
    MSG message;
    while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessage(&message);
    }
    engine.ProcessMessages();
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  if (!status) std::cerr << "PS1 WebRTC loopback did not finish in 65 seconds.\n";
  report.SetMethodCallHandler(nullptr);
  return status.value_or(4);
}
