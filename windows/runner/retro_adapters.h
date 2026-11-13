#ifndef RUNNER_RETRO_ADAPTERS_H_
#define RUNNER_RETRO_ADAPTERS_H_

#include <cstdint>
#include <string>
#include <vector>

// One graphics adapter DXGI lists, as the Auto Optimizer of a PS1 game in the emulator host
// reads it: its name (UTF-8) and its video memory of its own.
struct RetroAdapter {
  std::string name;
  std::int64_t dedicated_bytes;
};

// The graphics adapters DXGI lists, without the software ones. Empty when the list cannot be
// read whole.
std::vector<RetroAdapter> RetroAdapters();

#endif  // RUNNER_RETRO_ADAPTERS_H_
