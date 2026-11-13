cmake_minimum_required(VERSION 3.18)
project(anyps5_linux_channel_test LANGUAGES CXX)
enable_testing()

# Point at Flutter's engine/linux-x64 artifact directory. This is opt-in and
# does not download an SDK or require a desktop/display server to run.
set(FLUTTER_ENGINE_DIR "" CACHE PATH "Flutter Linux engine artifact directory")
if(NOT EXISTS "${FLUTTER_ENGINE_DIR}/flutter_linux/flutter_linux.h")
  message(FATAL_ERROR "Set FLUTTER_ENGINE_DIR to Flutter's Linux engine artifacts")
endif()
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)
pkg_check_modules(DEVICES REQUIRED IMPORTED_TARGET egl epoxy libpulse)
find_library(FLUTTER_ENGINE flutter_linux_gtk PATHS "${FLUTTER_ENGINE_DIR}" NO_DEFAULT_PATH REQUIRED)

add_executable(retro_linux_channel_test retro_linux_channel_test.cpp)
target_compile_features(retro_linux_channel_test PRIVATE cxx_std_17)
target_include_directories(retro_linux_channel_test PRIVATE "${FLUTTER_ENGINE_DIR}" "../../../native/retro" "../../../native/retro/test")
target_link_libraries(retro_linux_channel_test PRIVATE "${FLUTTER_ENGINE}" PkgConfig::GTK)
add_test(NAME linux_channel_values COMMAND retro_linux_channel_test)

# Compile the actual application adapter and device implementations as well.
# This catches ABI/header drift that pure value tests would not exercise.
add_library(retro_linux_bridge_check OBJECT ../retro_core_host_linux.cc ../retro_linux_audio.cc ../retro_linux_video.cc)
target_compile_features(retro_linux_bridge_check PRIVATE cxx_std_17)
target_compile_options(retro_linux_bridge_check PRIVATE -Wall -Wextra -Werror)
target_include_directories(retro_linux_bridge_check PRIVATE "${FLUTTER_ENGINE_DIR}" "../../../native/retro")
target_link_libraries(retro_linux_bridge_check PRIVATE PkgConfig::GTK PkgConfig::DEVICES)
