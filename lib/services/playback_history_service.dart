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
  final _audioService = GetIt.instance<MusicPlayerBackgroundTask>();
  final _queueService = GetIt.instance<QueueService>();
  final _playbackHistoryServiceLogger = Logger("PlaybackHistoryService");

  // internal state

  final List<HistoryItem> _history = []; // contains **all** items that have been played, including "next up"
  HistoryItem? _currentTrack; // the currently playing track

  PlaybackState? _previousPlaybackState;
  final bool _reportQueueToServer = true;
  DateTime _lastPositionUpdate = DateTime.now();

  final _historyStream = BehaviorSubject<List<HistoryItem>>.seeded(
    List.empty(growable: true),
  ); 

  PlaybackHistoryService() {

    _queueService.getCurrentTrackStream().listen((currentTrack) {
      updateCurrentTrack(currentTrack);

      if (currentTrack == null) {
        _reportPlaybackStopped();
      }
    });

    _audioService.playbackState.listen((event) {

      final prevState = _previousPlaybackState;
      final prevItem = _currentTrack?.item;
      final currentState = event;
      final currentIndex = currentState.queueIndex;

      //TODO check if this is a race condition
      final currentItem = _queueService.getCurrentTrack();

      if (currentIndex != null && currentItem != null) {

        // handle events that don't change the current track (e.g. loop, pause, seek, etc.)

        // differences in queue index or item id are considered track changes
        if (currentItem.id != prevItem?.id || (_reportQueueToServer && currentIndex != prevState?.queueIndex)) {
          _playbackHistoryServiceLogger.fine("Reporting track change event from ${prevItem?.item.title} to ${currentItem.item.title}");
          onTrackChanged(currentItem, currentState, prevItem, prevState);
        }
        // handle play/pause events
        else if (currentState.playing != prevState?.playing) {
          _playbackHistoryServiceLogger.fine("Reporting play/pause event for ${currentItem.item.title}");
          onPlaybackStateChanged(currentItem, currentState);
        }
        // handle seeking (changes updateTime (= last abnormal position change))
        else if (currentState.playing && currentState.updateTime != prevState?.updateTime && currentState.bufferedPosition == prevState?.bufferedPosition) {

          // detect looping a single track
          if (
            // same track
            prevItem?.id == currentItem.id &&
            // last position was close to the end of the track
            (prevState?.position.inMilliseconds ?? 0) >= ((prevItem?.item.duration?.inMilliseconds ?? 0) - 1000 * 10) &&
            // current position is close to the beginning of the track
            currentState.position.inMilliseconds <= 1000 * 10
          ) {
            onTrackChanged(currentItem, currentState, prevItem, prevState);
            return;
          }

          // rate limit updates (only send update after no changes for 5 seconds)
          Future.delayed(const Duration(seconds: 5, milliseconds: 500), () {
            if (_lastPositionUpdate.add(const Duration(seconds: 5)).isBefore(DateTime.now())) {
              _playbackHistoryServiceLogger.fine("Reporting seek event for ${currentItem.item.title}");
              onPlaybackStateChanged(currentItem, currentState);
            }
            _lastPositionUpdate = DateTime.now();
          });
          
        }
        // maybe handle toggling shuffle when sending the queue? would result in duplicate entries in the activity log, so maybe it's not desirable
        // same for updating the queue / next up

        //TODO fix stop button not sending a playback state change event

      }

      _previousPlaybackState = event;
    });

    //TODO Tell Jellyfin we're not / no longer playing audio on startup
    // if (!FinampSettingsHelper.finampSettings.isOffline) {
      //FIXME why is an ID required? which ID should we use? an empty string doesn't work...
      // final playbackInfo = generatePlaybackProgressInfoFromState(const MediaItem(id: "", title: ""), _audioService.playbackState.valueOrNull ?? PlaybackState());
      // if (playbackInfo != null) {
        // _playbackHistoryServiceLogger.info("Stopping playback progress after startup");
        // _jellyfinApiHelper.stopPlaybackProgress(playbackInfo);
      // }
    // }
    
  }

  get history => _history;
  BehaviorSubject<List<HistoryItem>> get historyStream => _historyStream;

  /// method that converts history into a list grouped by date
  List<MapEntry<DateTime, List<HistoryItem>>> getHistoryGroupedByDate() {
    final groupedHistory = <MapEntry<DateTime, List<HistoryItem>>>[];

    final groupedHistoryMap = <DateTime, List<HistoryItem>>{};

    _history.forEach((element) {
      final date = DateTime(
        element.startTime.year,
        element.startTime.month,
        element.startTime.day,
      );

      if (groupedHistoryMap.containsKey(date)) {
        groupedHistoryMap[date]!.add(element);
      } else {
        groupedHistoryMap[date] = [element];
      }
    });

    groupedHistoryMap.forEach((key, value) {
      groupedHistory.add(MapEntry(key, value));
    });

    // sort by date (most recent first)
    groupedHistory.sort((a, b) => b.key.compareTo(a.key));

    return groupedHistory;
  }

  /// method that converts history into a list grouped by minute
  List<MapEntry<DateTime, List<HistoryItem>>> getHistoryGroupedByHour() {
    final groupedHistory = <MapEntry<DateTime, List<HistoryItem>>>[];

    final groupedHistoryMap = <DateTime, List<HistoryItem>>{};

    _history.forEach((element) {
      final date = DateTime(
        element.startTime.year,
        element.startTime.month,
        element.startTime.day,
        element.startTime.hour,
      );

      if (groupedHistoryMap.containsKey(date)) {
        groupedHistoryMap[date]!.add(element);
      } else {
        groupedHistoryMap[date] = [element];
      }
    });

    groupedHistoryMap.forEach((key, value) {
      groupedHistory.add(MapEntry(key, value));
    });

    // sort by minute (most recent first)
    groupedHistory.sort((a, b) => b.key.compareTo(a.key));

    return groupedHistory;
  }

  void updateCurrentTrack(QueueItem? currentTrack) {

    if (currentTrack == null || currentTrack == _currentTrack?.item || currentTrack.item.id == "" || currentTrack.id == _currentTrack?.item.id) {
      // current track hasn't changed
      return;
    }

    // if there is a **previous** track
    if (_currentTrack != null) {
      // update end time of previous track
      _currentTrack!.endTime = DateTime.now();
    }

    // if there is a **current** track
    _currentTrack = HistoryItem(
      item: currentTrack,
      startTime: DateTime.now(),
    );
    _history.add(_currentTrack!); // current track is always the last item in the history

    _historyStream.add(_history);

  }

  //TODO separate starting a track and finishing a track and rely on the information provided by the queue service
  /// Report track changes to the Jellyfin Server if the user is not offline.
  Future<void> onTrackChanged(
    QueueItem currentItem,
    PlaybackState currentState,
    QueueItem? previousItem,
    PlaybackState? previousState,
  ) async {
    if (FinampSettingsHelper.finampSettings.isOffline) {
      return;
    }

    if (previousItem != null &&
        previousState != null &&
        // don't submit stop events for idle tracks (at position 0 and not playing)
        (previousState.playing ||
            previousState.updatePosition != Duration.zero)) {
      final playbackData = generatePlaybackProgressInfoFromState(
        previousItem.item,
        previousState,
      );

      if (playbackData != null) {
        _playbackHistoryServiceLogger.info("Stopping playback progress for ${previousItem.item.title}");
        await _jellyfinApiHelper.stopPlaybackProgress(playbackData);
      }
    }

    // prevent reporting the same track twice if playback hasn't started yet
    if (!currentState.playing) {
      return;
    }

    final playbackData = generatePlaybackProgressInfoFromState(
      currentItem.item,
      currentState,
    );

    if (playbackData != null) {
      _playbackHistoryServiceLogger.info("Starting playback progress for ${currentItem.item.title}");
      await _jellyfinApiHelper.reportPlaybackStart(playbackData);
    }
  }

  /// Report track changes to the Jellyfin Server if the user is not offline.
  Future<void> onPlaybackStateChanged(
    QueueItem currentItem,
    PlaybackState currentState,
  ) async {
    if (FinampSettingsHelper.finampSettings.isOffline) {
      return;
    }

    final playbackData = generatePlaybackProgressInfoFromState(
      currentItem.item,
      currentState,
    );

    if (playbackData != null) {
      _playbackHistoryServiceLogger.info("Starting playback progress for ${currentItem.item.title}");
      await _jellyfinApiHelper.reportPlaybackStart(playbackData);
    }
  }

  /// Generates PlaybackProgressInfo for the supplied item and playback state.
  jellyfin_models.PlaybackProgressInfo? generatePlaybackProgressInfoFromState(
    MediaItem item,
    PlaybackState state,
  ) {
    final duration = item.duration;
    return generatePlaybackProgressInfo(
      item,
      isPaused: !state.playing,
      // always consider as unmuted
      isMuted: false,
      // ensure the (extrapolated) position doesn't exceed the duration
      playerPosition: duration != null && state.position > duration
          ? duration
          : state.position,
      repeatMode: _jellyfinRepeatModeFromRepeatMode(state.repeatMode),
      includeNowPlayingQueue: _reportQueueToServer,
    );
  }

  Future<void> _reportPlaybackStopped() async {

    final playbackInfo = generateGenericPlaybackProgressInfo();
    if (playbackInfo != null) {
      await _jellyfinApiHelper.stopPlaybackProgress(playbackInfo);
    }
    
  }

  // Future<void> _reportPlaybackStarted() async {

  //   final playbackInfo = generatePlaybackProgressInfo();
  //   if (playbackInfo != null) {
  //     await _jellyfinApiHelper.reportPlaybackStart(playbackInfo);
  //   }
    
  // }

  /// Generates PlaybackProgressInfo for the supplied item and player info.
  jellyfin_models.PlaybackProgressInfo? generatePlaybackProgressInfo(
    MediaItem item, {
    required bool isPaused,
    required bool isMuted,
    required Duration playerPosition,
    required String repeatMode,
    required bool includeNowPlayingQueue,
  }) {
    try {

      List<jellyfin_models.QueueItem>? nowPlayingQueue;
      if (includeNowPlayingQueue) {
        nowPlayingQueue = _queueService.getNextXTracksInQueue(30)
            .map((e) => jellyfin_models.QueueItem(
              id: e.item.id,
              playlistItemId: e.source.id,
            ))
            .toList();
      }
      
      return jellyfin_models.PlaybackProgressInfo(
        itemId: item.extras?["itemJson"]["Id"] ?? "",
        isPaused: isPaused,
        isMuted: isMuted,
        positionTicks: playerPosition.inMicroseconds * 10,
        repeatMode: repeatMode,
        playMethod: item.extras?["shouldTranscode"] ?? false
            ? "Transcode"
            : "DirectPlay",
        nowPlayingQueue: nowPlayingQueue,
      );
    } catch (e) {
      _playbackHistoryServiceLogger.severe(e);
      return null;
      // rethrow;
    }
  }

  /// Generates PlaybackProgressInfo from current player info.
  jellyfin_models.PlaybackProgressInfo? generateGenericPlaybackProgressInfo({
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

  String _jellyfinRepeatModeFromRepeatMode(AudioServiceRepeatMode repeatMode) {
    switch (repeatMode) {
      case AudioServiceRepeatMode.none:
        return "RepeatNone";
      case AudioServiceRepeatMode.one:
        return "RepeatOne";
      case AudioServiceRepeatMode.all:
      case AudioServiceRepeatMode.group:
        return "RepeatAll";
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
