import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:audio_service/audio_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';
import 'package:uuid/uuid.dart';

import 'finamp_user_helper.dart';
import 'jellyfin_api_helper.dart';
import 'finamp_settings_helper.dart';
import '../models/finamp_models.dart';
import '../models/jellyfin_models.dart' as jellyfin_models;

/// A track queueing service for Finamp.
class PlaybackHistoryService {
  final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final _finampUserHelper = GetIt.instance<FinampUserHelper>();
  final _audioService = GetIt.instance<MusicPlayerBackgroundTask>();
  final _queueService = GetIt.instance<QueueService>();
  final _playbackHistoryServiceLogger = Logger("PlaybackHistoryService");

  // internal state

  List<HistoryItem> _history = []; // contains **all** items that have been played, including "next up"
  HistoryItem? _currentTrack; // the currently playing track

  final _historyStream = BehaviorSubject<List<HistoryItem>>.seeded(
    List.empty(growable: true),
  ); 

  PlaybackHistoryService() {

    _queueService.getCurrentTrackStream().listen((currentTrack) {
      updateCurrentTrack(currentTrack);
    });

    _audioService.getPlaybackEventStream().listen((event) {
      _updatePlaybackProgress();
      if (_audioService.paused) {
        _playbackHistoryServiceLogger.info("Playback paused.");
      } else {
        _playbackHistoryServiceLogger.info("Playback resumed.");
      }
    });
    
  }

  get history => _history;
  BehaviorSubject<List<HistoryItem>> get historyStream => _historyStream;

  //TODO handle events that don't change the current track (e.g. pause, seek, etc.)

  void updateCurrentTrack(QueueItem? currentTrack) {

    bool playbackStarted = false;
    bool playbackStopped = false;

    if (currentTrack == _currentTrack?.item || currentTrack?.item.id == "") {
      // current track hasn't changed
      return;
    }

    // update end time of previous track
    if (_currentTrack != null) {
      _currentTrack!.endTime = DateTime.now();
    } else {
      playbackStarted = true;
    }

    if (currentTrack != null) {
      _currentTrack = HistoryItem(
        item: currentTrack,
        startTime: DateTime.now(),
      );
      _history.add(_currentTrack!); // current track is always the last item in the history
    } else {
      playbackStopped = true;
    }

    _historyStream.add(_history);

    _updatePlaybackProgress(
      playbackStarted: playbackStarted,
      playbackStopped: playbackStopped,
    );
  }

  Future<void> _updatePlaybackProgress({
    bool playbackStarted = false,
    bool playbackPaused = false,
    bool playbackStopped = false,
  }) async {
    try {

      final playbackInfo = generatePlaybackProgressInfo();
      if (playbackInfo != null) {
        if (playbackStarted) {
          await _reportPlaybackStarted();
        } else if (playbackStopped) {
          await _reportPlaybackStopped();
        } else {
          await _jellyfinApiHelper.updatePlaybackProgress(playbackInfo);
        }
      }
    } catch (e) {
      _playbackHistoryServiceLogger.severe(e);
      return Future.error(e);
    }
  }

  Future<void> _reportPlaybackStopped() async {

    final playbackInfo = generatePlaybackProgressInfo();
    if (playbackInfo != null) {
      await _jellyfinApiHelper.stopPlaybackProgress(playbackInfo);
    }
    
  }

  Future<void> _reportPlaybackStarted() async {

    final playbackInfo = generatePlaybackProgressInfo();
    if (playbackInfo != null) {
      await _jellyfinApiHelper.reportPlaybackStart(playbackInfo);
    }
    
  }

  Future<bool> enrichHistoryFromPlaybackReporting() async {
    try {

      final playbackReportingResponse = await _jellyfinApiHelper.getPlaybackHistory(
        since: DateTime.now().subtract(const Duration(days: 14)),
      );

      final skipIds = _history.map((e) => e.item.item.id).toList();

      // fetch BaseItemDtos for all items
      List<jellyfin_models.BaseItemDto>? items = await _jellyfinApiHelper.getItemsByIds(
        itemIds: 
          playbackReportingResponse.results
            .map((e) => e[3] as String) //FIXME properly calculate the index
            .toSet()
            .where((e) => !skipIds.contains(e))
            .toList()
      );

      return false;

      Map<String, jellyfin_models.BaseItemDto> itemsMap = <String, jellyfin_models.BaseItemDto>{for (var item in items!) item.id: item};

      // convert the response to a list of HistoryItems
      // List<HistoryItem> historyItems = [];

      List<String> columns = playbackReportingResponse.colums; // intentional typo
      // generate a map from column name to index
      Map<String, int> columnMap = {};
      for (int i = 0; i < columns.length; i++) {
        columnMap[columns[i]] = i;
      }

      if (!columnMap.containsKey('ItemId') || !columnMap.containsKey('DateCreated') || !columnMap.containsKey('PlayDuration')) {
        return false;
      }

      final playbackHistory = await Future.wait(playbackReportingResponse.results.map((item) async {

        DateTime startTime = DateTime.parse(item[columnMap['DateCreated']!]);
        return HistoryItem(
          item: QueueItem(
            source: QueueItemSource(id: 'unknown', name: 'Playback Reporting', type: QueueItemSourceType.playbackReporting),
            type: QueueItemQueueType.previousTracks,
            item: await _queueService.generateMediaItem(itemsMap[item[columnMap['ItemId']!]]!)
            // id: item[columnMap['ItemId']!],
          ),
          startTime: startTime,
          endTime: startTime.add(Duration(seconds: item[columnMap['PlayDuration']!])),
        );
      }).toList());

      List<HistoryItem> newHistory = [];
      newHistory.addAll(_history);
      newHistory.addAll(playbackHistory);

      newHistory.sort((a, b) => a.startTime.compareTo(b.startTime));

      _history = newHistory;

      return true;

    } catch (e) {
      _playbackHistoryServiceLogger.severe(e);
      return Future.error(e);
    }
  }

  /// Generates PlaybackProgressInfo from current player info.
  jellyfin_models.PlaybackProgressInfo? generatePlaybackProgressInfo({
    bool includeNowPlayingQueue = false,
  }) {
    if (_history.isEmpty || _currentTrack == null) {
      // This function relies on _history having items
      return null;
    }

    try {

      final itemId = _currentTrack!.item.item.extras?["itemJson"]["Id"];

      if (itemId == null) {
        _playbackHistoryServiceLogger.warning(
          "Current track item ID is null, cannot generate playback progress info.",
        );
        return null;
      }
      
      return jellyfin_models.PlaybackProgressInfo(
        itemId: _currentTrack!.item.item.extras?["itemJson"]["Id"],
        isPaused: _audioService.paused,
        isMuted: _audioService.volume == 0.0,
        volumeLevel: _audioService.volume.round(),
        positionTicks: _audioService.playbackPosition.inMicroseconds * 10,
        repeatMode: _toJellyfinRepeatMode(_queueService.loopMode),
        playbackStartTimeTicks: _currentTrack!.startTime.millisecondsSinceEpoch * 1000 * 10,
        playMethod: _currentTrack!.item.item.extras!["shouldTranscode"]
            ? "Transcode"
            : "DirectPlay",
        // We don't send the queue since it seems useless and it can cause
        // issues with large queues.
        // https://github.com/jmshrv/finamp/issues/387
        nowPlayingQueue: includeNowPlayingQueue
            ? _queueService.getQueue().nextUp.followedBy(_queueService.getQueue().queue)
                .map(
                  (e) => jellyfin_models.QueueItem(
                      id: e.item.extras!["itemJson"]["Id"],
                      playlistItemId: e.item.id
                    ),
                ).toList()
            : null,
      );
    } catch (e) {
      _playbackHistoryServiceLogger.severe(e);
      rethrow;
    }
  }

  String _toJellyfinRepeatMode(LoopMode loopMode) {
    switch (loopMode) {
      case LoopMode.all:
        return "RepeatAll";
      case LoopMode.one:
        return "RepeatOne";
      case LoopMode.none:
        return "RepeatNone";
    }
  }
}
