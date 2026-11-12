cmake_minimum_required(VERSION 3.18)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "layer_overlay.cc"
  "retro_core_host_linux.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
# The retro host protocol client. Emulator cores run in the separate
# anyps5-retro-host program; nothing that loads a core is built here.
add_subdirectory("${CMAKE_SOURCE_DIR}/../native/retro_ipc" "${CMAKE_CURRENT_BINARY_DIR}/retro_ipc")
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK anyps5_retro_ipc)
# dlopen for gtk-layer-shell (layer_overlay.cc), which is loaded at run time, never linked.
target_link_libraries(${BINARY_NAME} PRIVATE ${CMAKE_DL_LIBS})

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
