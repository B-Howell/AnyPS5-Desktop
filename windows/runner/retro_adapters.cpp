#include "retro_adapters.h"

#include <dxgi.h>
#include <wrl/client.h>

#include <limits>

#include "utils.h"

std::vector<RetroAdapter> RetroAdapters() {
  Microsoft::WRL::ComPtr<IDXGIFactory1> factory;
  if (FAILED(::CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf())))) {
    return {};
  }
  std::vector<RetroAdapter> adapters;
  for (UINT index = 0;; ++index) {
    Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
    const HRESULT status = factory->EnumAdapters1(index, adapter.GetAddressOf());
    if (status == DXGI_ERROR_NOT_FOUND) {
      return adapters;
    }
    DXGI_ADAPTER_DESC1 description{};
    if (FAILED(status) || FAILED(adapter->GetDesc1(&description))) {
      return {};
    }
    if ((description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0) {
      continue;
    }
    std::string name = Utf8FromUtf16(description.Description);
    if (name.empty() ||
        description.DedicatedVideoMemory >
            static_cast<SIZE_T>(std::numeric_limits<std::int64_t>::max())) {
      return {};
    }
    adapters.push_back(
        {std::move(name), static_cast<std::int64_t>(description.DedicatedVideoMemory)});
  }
}
