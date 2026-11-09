#include "../ps1_netplay_timeline.h"

#include <cassert>

int main() {
  using ps1_netplay::FrameInput;
  using ps1_netplay::PadInput;
  using ps1_netplay::Timeline;

  Timeline host(0);
  Timeline guest(1);
  const PadInput host_pad{1, {101, -102, 103, -104}};
  const PadInput guest_pad{2, {-201, 202, -203, 204}};
  std::array<PadInput, 2> host_inputs{};
  std::array<PadInput, 2> guest_inputs{};
  assert(!host.Prepare(host_pad, host_inputs));
  assert(host.frame() == 0 && !host.confirmed() && !host.received());
  assert(host.LocalPacket().size() == 2);
  host.Start();
  guest.Start();
  assert(!host.Prepare(host_pad, host_inputs));
  assert(host.LocalPacket().back() == (FrameInput{2, host_pad}));
  assert(host.Receive(guest.LocalPacket(), std::nullopt));
  assert(guest.Receive(host.LocalPacket(), std::nullopt));
  assert(host.Prepare({}, host_inputs) && guest.Prepare(guest_pad, guest_inputs));
  assert(host_inputs == guest_inputs);
  assert(host_inputs == (std::array<PadInput, 2>{}));
  host.Commit();
  guest.Commit();
  assert(host.confirmed() == 0u && host.frame() == 1);

  assert(host.Receive(guest.LocalPacket(), guest.received()));
  assert(guest.Receive(host.LocalPacket(), host.received()));
  assert(host.Prepare({}, host_inputs) && guest.Prepare({}, guest_inputs));
  assert(host_inputs == guest_inputs);
  host.Commit();
  guest.Commit();
  assert(host.Prepare({}, host_inputs) && guest.Prepare({}, guest_inputs));
  assert(host_inputs == guest_inputs);
  assert(host_inputs[0] == host_pad && host_inputs[1] == guest_pad);
  host.Commit();
  guest.Commit();

  // Invalid ACKs, speculative future input, and conflicting redundant inputs
  // leave the receiver's acknowledged frame untouched.
  const auto before = host.received();
  assert(!host.Receive({{4, {}}}, 1000));
  assert(!host.Receive({{4, {}}, {1000, {}}}, std::nullopt));
  assert(!host.Receive({{2, host_pad}}, std::nullopt));
  assert(host.received() == before);
  assert(host.Receive({{4, {}}}, std::nullopt));
  assert(host.received() == before);
  assert(host.Receive({{3, {}}}, std::nullopt));
  assert(host.received() == 4u);
  assert(host.Receive({{3, {}}}, std::nullopt));
  assert(host.received() == 4u);

  // A full, long run keeps memory and retransmission bounded.
  for (int tick = 0; tick < 2000; ++tick) {
    assert(host.Receive(guest.LocalPacket(), guest.received()));
    assert(guest.Receive(host.LocalPacket(), host.received()));
    assert(host.Prepare({}, host_inputs) && guest.Prepare({}, guest_inputs));
    assert(host_inputs == guest_inputs);
    host.Commit();
    guest.Commit();
    assert(host.LocalPacket().size() <= 8);
    assert(guest.LocalPacket().size() <= 8);
  }
  assert(host.frame() == 2003 && host.frame() == guest.frame());
}
