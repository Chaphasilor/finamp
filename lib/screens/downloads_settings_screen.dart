import 'package:finamp/components/AlbumScreen/download_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:hive/hive.dart';

import '../models/finamp_models.dart';
import '../services/finamp_settings_helper.dart';
import 'downloads_location_screen.dart';

class DownloadsSettingsScreen extends StatelessWidget {
  const DownloadsSettingsScreen({super.key});

  static const routeName = "/settings/downloads";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.downloadSettings),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.folder),
            title: Text(AppLocalizations.of(context)!.downloadLocations),
            onTap: () => Navigator.of(context)
                .pushNamed(DownloadsLocationScreen.routeName),
          ),
          const RequireWifiSwitch(),
          const ShowPlaylistSongsSwitch(),
          const ConcurentDownloadsSelector(),
          ListTile(
            // TODO real UI for this
            title: const Text("Download all favorites"),
            trailing: DownloadButton(
                item: DownloadStub.fromId(
                    id: "Favorites", type: DownloadItemType.finampCollection)),
          ),
          const SyncOnStartupSwitch(),
          const PreferQuickSyncsSwitch(),
          const DownloadWorkersSelector(),
        ],
      ),
    );
  }
}

class RequireWifiSwitch extends StatelessWidget {
  const RequireWifiSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Box<FinampSettings>>(
      valueListenable: FinampSettingsHelper.finampSettingsListener,
      builder: (context, box, child) {
        bool? requireWifi = box.get("FinampSettings")?.requireWifiForDownloads;

        return SwitchListTile.adaptive(
          title: Text(AppLocalizations.of(context)!.requireWifiForDownloads),
          value: requireWifi ?? false,
          onChanged: requireWifi == null
              ? null
              : (value) {
                  FinampSettings finampSettingsTemp =
                      box.get("FinampSettings")!;
                  finampSettingsTemp.requireWifiForDownloads = value;
                  box.put("FinampSettings", finampSettingsTemp);
                },
        );
      },
    );
  }
}

class ShowPlaylistSongsSwitch extends StatelessWidget {
  const ShowPlaylistSongsSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Box<FinampSettings>>(
      valueListenable: FinampSettingsHelper.finampSettingsListener,
      builder: (context, box, child) {
        bool? showUnknownItems =
            box.get("FinampSettings")?.showDownloadsWithUnknownLibrary;

        return SwitchListTile.adaptive(
          title: Text(AppLocalizations.of(context)!.showPlaylistSongs),
          subtitle:
              Text(AppLocalizations.of(context)!.showPlaylistSongsSubtitle),
          value: showUnknownItems ?? true,
          onChanged: showUnknownItems == null
              ? null
              : (value) {
                  FinampSettings finampSettingsTemp =
                      box.get("FinampSettings")!;
                  finampSettingsTemp.showDownloadsWithUnknownLibrary = value;
                  box.put("FinampSettings", finampSettingsTemp);
                },
        );
      },
    );
  }
}

class SyncOnStartupSwitch extends StatelessWidget {
  const SyncOnStartupSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Box<FinampSettings>>(
      valueListenable: FinampSettingsHelper.finampSettingsListener,
      builder: (context, box, child) {
        bool? syncOnStartup = box.get("FinampSettings")?.resyncOnStartup;

        return SwitchListTile.adaptive(
          title: Text(AppLocalizations.of(context)!.syncOnStartupSwitch),
          value: syncOnStartup ?? true,
          onChanged: syncOnStartup == null
              ? null
              : (value) {
                  FinampSettings finampSettingsTemp =
                      box.get("FinampSettings")!;
                  finampSettingsTemp.resyncOnStartup = value;
                  box.put("FinampSettings", finampSettingsTemp);
                },
        );
      },
    );
  }
}

class PreferQuickSyncsSwitch extends StatelessWidget {
  const PreferQuickSyncsSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Box<FinampSettings>>(
      valueListenable: FinampSettingsHelper.finampSettingsListener,
      builder: (context, box, child) {
        bool? preferQuicksyncs = box.get("FinampSettings")?.preferQuickSyncs;

        return SwitchListTile.adaptive(
          title: Text(AppLocalizations.of(context)!.preferQuickSyncSwitch),
          subtitle:
              Text(AppLocalizations.of(context)!.preferQuickSyncSwitchSubtitle),
          value: preferQuicksyncs ?? true,
          onChanged: preferQuicksyncs == null
              ? null
              : (value) {
                  FinampSettings finampSettingsTemp =
                      box.get("FinampSettings")!;
                  finampSettingsTemp.preferQuickSyncs = value;
                  box.put("FinampSettings", finampSettingsTemp);
                },
        );
      },
    );
  }
}

class ConcurentDownloadsSelector extends StatelessWidget {
  const ConcurentDownloadsSelector({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          title: Text(AppLocalizations.of(context)!.maxConcurrentDownloads),
          subtitle: Text(
              AppLocalizations.of(context)!.maxConcurrentDownloadsSubtitle),
        ),
        ValueListenableBuilder<Box<FinampSettings>>(
          valueListenable: FinampSettingsHelper.finampSettingsListener,
          builder: (context, box, child) {
            final finampSettings = box.get("FinampSettings")!;

            return Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Slider(
                  min: 1,
                  max: 100,
                  value: finampSettings.maxConcurrentDownloads.toDouble(),
                  label: AppLocalizations.of(context)!
                      .maxConcurrentDownloadsLabel(
                          finampSettings.maxConcurrentDownloads.toString()),
                  onChanged: (value) {
                    FinampSettings finampSettingsTemp =
                        box.get("FinampSettings")!;
                    finampSettingsTemp.maxConcurrentDownloads = value.toInt();
                    box.put("FinampSettings", finampSettingsTemp);
                  },
                ),
                Text(
                  AppLocalizations.of(context)!.maxConcurrentDownloadsLabel(
                      finampSettings.maxConcurrentDownloads.toString()),
                  style: Theme.of(context).textTheme.titleLarge,
                )
              ],
            );
          },
        ),
      ],
    );
  }
}

class DownloadWorkersSelector extends StatelessWidget {
  const DownloadWorkersSelector({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          title: Text(AppLocalizations.of(context)!.downloadsWorkersSetting),
          subtitle: Text(
              AppLocalizations.of(context)!.downloadsWorkersSettingSubtitle),
        ),
        ValueListenableBuilder<Box<FinampSettings>>(
          valueListenable: FinampSettingsHelper.finampSettingsListener,
          builder: (context, box, child) {
            final finampSettings = box.get("FinampSettings")!;

            return Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Slider(
                  min: 1,
                  max: 30,
                  value: finampSettings.downloadWorkers.toDouble(),
                  label: AppLocalizations.of(context)!
                      .downloadsWorkersSettingLabel(
                          finampSettings.downloadWorkers.toString()),
                  onChanged: (value) {
                    FinampSettings finampSettingsTemp =
                        box.get("FinampSettings")!;
                    finampSettingsTemp.downloadWorkers = value.toInt();
                    box.put("FinampSettings", finampSettingsTemp);
                  },
                ),
                Text(
                  AppLocalizations.of(context)!.downloadsWorkersSettingLabel(
                      finampSettings.downloadWorkers.toString()),
                  style: Theme.of(context).textTheme.titleLarge,
                )
              ],
            );
          },
        ),
      ],
    );
  }
}
