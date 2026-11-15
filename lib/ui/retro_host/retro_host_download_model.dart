import 'dart:async';

import '../../core/audio/tones.dart';
import '../../core/retro_host/retro_host_release.dart';
import '../../core/retro_host/retro_host_store.dart';
import '../../core/toolkit_download.dart';
import '../app_model.dart';
import '../components.dart';
import '../strings.dart';

/// The PS1 emulator host as a managed download, as ffmpeg is: Settings › Emulators offers it from
/// the host repository's signed releases, the player presses to download or update it, and it is
/// checked on download and before every game ([RetroHostStore]). A debug build that runs the host
/// `ANYPS5_RETRO_HOST` names offers none.
class RetroHostDownloadModel {
  RetroHostDownloadModel(this.app)
    : store = RetroHostStore(app.paths.retroHost, keys: app.services.retroHostReleases?.signingKeys);

  final AppModel app;
  final RetroHostStore store;

  /// The last look found no signed host release yet.
  bool notYet = false;

  /// Why the last download failed; a sentence, or null.
  String? error;

  /// Why the installed host failed its check before a start, until it is downloaded again.
  String? broken;

  ToolkitProgress? progress;
  DownloadCancel? _cancel;
  bool get downloading => _cancel != null;

  /// The new host is being put in place of the old: no host may start until it is.
  bool installing = false;

  /// Whether this launcher can download a host: it has the releases to read and a system the host
  /// is released for.
  bool get offered => app.services.retroHostReleases != null && store.system != null;

  /// The installed host failed its check before a start: [reason] says how. Its row then offers it
  /// again.
  void failedCheck(String reason) {
    broken = reason;
    app.refresh();
  }

  /// Downloads the newest signed host, or a newer one than the installed host, checks it and puts
  /// it in place. Runs only when the player pressed for it; said to the player however it ends.
  /// The first host installed turns on Run PS1 games in the separate host.
  Future<void> download() async {
    if (downloading) return;
    final source = app.services.retroHostReleases;
    if (source == null || store.system == null) return;
    if (_hostInUse) {
      app.show(T.text('retroHostDownloadCloseGame'));
      return;
    }
    final cancel = DownloadCancel();
    _cancel = cancel;
    error = null;
    notYet = false;
    progress = const ToolkitProgress(ToolkitPhase.download, 0, 0);
    app.refresh();
    final before = store.version;
    var shown = -1;
    try {
      final release = RetroHostStore.newest(await source.all());
      final offered = release == null ? null : RetroHostVersion.tryParse(release.version);
      if (before != null && broken == null && offered != null && offered.compareTo(before) <= 0) {
        app.show(T.format('retroHostUpToDate', ['$before']));
        return;
      }
      final download = await store.fetch(
        release,
        cancel: cancel,
        onProgress: (next) {
          progress = next;
          final step = (next.fraction * 200).floor();
          if (step != shown) {
            shown = step;
            app.refresh();
          }
        },
      );
      progress = const ToolkitProgress(ToolkitPhase.unpack, 1, 1);
      installing = true;
      app.refresh();
      await app.stopKeptRetroHost();
      if (_hostInUse) throw ToolkitFailure(ToolkitFailureKind.badLayout, T.text('retroHostDownloadCloseGame'));
      final version = await store.putInPlace(download);
      broken = null;
      if (before == null) app.setRetroHostPs1(true);
      app.sounds.play(Cue.unlocked);
      app.show(T.format('retroHostReady', ['$version']));
    } on ToolkitFailure catch (failure) {
      switch (failure.kind) {
        case ToolkitFailureKind.cancelled:
          break;
        case ToolkitFailureKind.notAvailable:
          notYet = true;
          app.show(T.text('retroHostNotYet'));
        default:
          error = failure.message;
          app.show(T.format('retroHostDownloadFailed', [failure.message]));
      }
    } finally {
      installing = false;
      _cancel = null;
      progress = null;
      app.refresh();
    }
  }

  /// Stops the download; what came is kept, to carry on next time.
  void cancel() => _cancel?.cancel();

  /// A game plays in a host, or an online match is starting one.
  bool get _hostInUse => app.retroPlay != null || app.retroOnline != null;

  /// Settings › Emulators' row for the download: one press to download the host, then how it
  /// goes; once installed, its version, and a press looks for a newer one. Nothing where no host
  /// can be downloaded, or the debug host `ANYPS5_RETRO_HOST` names is used.
  List<PanelRow> rows({required bool debugHost}) {
    if (!offered || debugHost) return const [];
    if (downloading) {
      final now = progress;
      return [
        PanelRow(
          id: 'retro-host-download',
          title: T.format('retroHostDownloading', [((now?.fraction ?? 0) * 100).floor()]),
          detail: T.format('retroHostProgress', [
            switch (now?.phase) {
              ToolkitPhase.download when (now?.total ?? 0) > 0 => T.format('engineProgress', [
                byteText(now!.received),
                byteText(now.total),
              ]),
              ToolkitPhase.unpack || ToolkitPhase.finish => T.text('retroHostChecking'),
              _ => T.text('retroHostLooking'),
            },
          ]),
          kind: ActionRow(cancel),
        ),
      ];
    }
    final version = store.installed() == null ? null : store.version;
    final String detail;
    if (broken != null) {
      detail = T.text('retroHostBrokenDetail');
    } else if (error != null) {
      detail = error!;
    } else if (notYet) {
      detail = T.text('retroHostNotYet');
    } else {
      detail = T.text(version == null ? 'retroHostDownloadDetail' : 'retroHostInstalledDetail');
    }
    return [
      PanelRow(
        id: 'retro-host-download',
        title: version == null || broken != null
            ? T.text('retroHostDownload')
            : T.format('retroHostInstalled', ['$version']),
        detail: detail,
        kind: ActionRow(() => unawaited(download())),
      ),
    ];
  }
}
