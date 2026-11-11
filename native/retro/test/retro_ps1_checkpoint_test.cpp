#include "retro_session.h"
#include "retro_library.h"
#include "retro_test_support.h"

#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>

using namespace anyps5::retro;
using namespace anyps5::retro::test;

int main(int argc, char** argv) {
  std::filesystem::path saves;
  try {
    Check(argc == 3, "Pass the checkpoint and ordinary core fixtures");
    saves = std::filesystem::temp_directory_path() /
        ("anyps5-ps1-checkpoint-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directory(saves);
    const DynamicLibrary library(std::filesystem::u8path(argv[1]));
    const auto wrong_thread = library.Get<bool (*)()>("test_wrong_disk_thread");
    const auto hold_tray = library.Get<void (*)(bool)>("test_checkpoint_hold_tray");
    const auto tray_entered = library.Get<bool (*)()>("test_checkpoint_tray_entered");
    const auto hold_export = library.Get<void (*)(bool)>("test_checkpoint_hold_export");
    const auto export_entered = library.Get<bool (*)()>("test_checkpoint_export_entered");
    Session session({argv[1], "test.m3u", "", saves.u8string(), "", {}},
                    std::make_unique<TestVideo>(), std::make_unique<TestAudio>(), [] {});
    ps1_checkpoint::Digest digest{};
    Check(!session.RequestOrdinaryCheckpoint(1, digest, true), "Checkpoint accepted before core boot");
    session.Start();
    WaitFor([&] { session.AcquireFrame(); return session.Status().checkpoint_source > 0 || session.ended(); },
            "PS1 core did not advertise its checkpoint contract");
    Check(session.Status().error.empty(), session.Status().error.c_str());
    session.Pause(true);
    Check(session.Status().options.at("swanstation_CPU_ExecutionMode").values.size() == 2,
          "Checkpoint fixture did not expose a real configuration choice");
    const auto source = session.Status().checkpoint_source;
    hold_tray(true);
    Check(session.ChangeDisc(1), "Could not queue the fixture disc change");
    WaitFor([&] { return tray_entered(); }, "Core never entered the disc callback");
    const auto during_disc = session.RequestOrdinaryCheckpoint(source, digest, true);
    hold_tray(false);
    Check(!during_disc, "A checkpoint captured media during an in-flight disc change");
    WaitFor([&] { return !session.Status().discs->busy; }, "Disc change did not complete");
    Check(session.ChangeDisc(0), "Could not return to the original media");
    WaitFor([&] { return !session.Status().discs->busy; }, "Original disc did not return");
    Check(!session.RequestOrdinaryCheckpoint(source + 1, digest, true), "Wrong ordinary source accepted");
    const auto ticket = session.RequestOrdinaryCheckpoint(source, digest, true);
    Check(ticket.has_value(), "Ordinary game could not request park");
    ps1_checkpoint::Mailbox::Reply reply;
    WaitFor([&] { reply = session.TakeCheckpoint(*ticket); return !std::holds_alternative<std::monostate>(reply); },
            "Ordinary export did not finish while the Quick Menu was open");
    const auto* snapshot = std::get_if<ps1_checkpoint::Snapshot>(&reply);
    Check(snapshot && snapshot->state.size() == 8 && session.Status().checkpoint_parked, "Missing parked checkpoint");
    uint32_t card = 99;
    std::memcpy(&card, snapshot->state.data() + 4, 4);
    Check(card == 0, "Public checkpoint included the private memory card");
    const auto steps = session.Status().telemetry.steps;
    session.Pause(false);
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
    Check(session.Status().telemetry.steps == steps, "Parked game kept executing");
    Check(!session.ChangeDisc(1), "Parked game accepted a disc change");
    Check(!session.SetOption("swanstation_CPU_ExecutionMode", "CachedInterpreter"), "Parked game accepted configuration changes");
    session.Pause(true);
    const auto resume = session.RequestOrdinaryResume(source);
    Check(resume.has_value(), "Original game could not request resume");
    WaitFor([&] { reply = session.TakeCheckpoint(*resume); return !std::holds_alternative<std::monostate>(reply); },
            "Private restore did not finish while the Quick Menu was open");
    Check(std::get<bool>(reply) && !session.Status().checkpoint_parked, "Private restore did not unpark");
    session.Pause(false);
    WaitFor([&] { return session.Status().telemetry.steps > steps + 1; }, "Original game did not continue");
    hold_export(true);
    Check(session.RequestOrdinaryCheckpoint(source, digest, true).has_value(), "Could not queue final park");
    WaitFor([&] { return export_entered(); }, "Core never entered the final exporter");
    const auto stopped_at = session.Status().telemetry.steps;
    session.Stop();
    hold_export(false);
    session.Join();
    Check(session.Status().telemetry.steps == stopped_at, "Core stepped after stop during checkpoint export");
    Check(!wrong_thread(), "Checkpoint hook ran outside the emulation worker");
    Check(!session.Status().checkpoint_source && !session.RequestOrdinaryResume(source), "Ended source accepted work");
    const auto card_file = saves / "test.srm";
    std::ifstream stored(card_file, std::ios::binary);
    stored.read(reinterpret_cast<char*>(&card), sizeof(card));
    Check(stored.good() && card == 7, "Private memory card was lost during park/resume");
    stored.close();
    Session ordinary({argv[2], "test.cue", "", saves.u8string(), "", {}},
                     std::make_unique<TestVideo>(), std::make_unique<TestAudio>(), [] {});
    ordinary.Start();
    WaitFor([&] { ordinary.AcquireFrame(); return ordinary.Status().presented || ordinary.ended(); },
            "Ordinary core without private hooks did not boot");
    Check(ordinary.Status().error.empty() && !ordinary.Status().checkpoint_source &&
          !ordinary.RequestOrdinaryCheckpoint(source, digest, false),
          "An ordinary core required or advertised private checkpoint hooks");
    ordinary.Stop(); ordinary.Join();
    std::filesystem::remove_all(saves);
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    if (!saves.empty()) std::filesystem::remove_all(saves);
    return 1;
  }
}
