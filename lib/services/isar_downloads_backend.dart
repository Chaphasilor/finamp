import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:collection/collection.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/services/isar_downloads.dart';
import 'package:get_it/get_it.dart';
import 'package:isar/isar.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path_helper;

import '../models/finamp_models.dart';
import '../models/jellyfin_models.dart';
import 'finamp_settings_helper.dart';
import 'finamp_user_helper.dart';
import 'jellyfin_api_helper.dart';

part 'isar_downloads_backend.g.dart';

class IsarPersistentStorage implements PersistentStorage {
  final _isar = GetIt.instance<Isar>();

  @override
  Future<void> storeTaskRecord(TaskRecord record) =>
      _store(IsarTaskDataType.taskRecord, record.taskId, record);

  @override
  Future<TaskRecord?> retrieveTaskRecord(String taskId) =>
      _get(IsarTaskDataType.taskRecord, taskId);

  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() =>
      _getAll(IsarTaskDataType.taskRecord);

  @override
  Future<void> removeTaskRecord(String? taskId) =>
      _remove(IsarTaskDataType.taskRecord, taskId);

  @override
  Future<void> storePausedTask(Task task) =>
      _store(IsarTaskDataType.pausedTask, task.taskId, task);

  @override
  Future<Task?> retrievePausedTask(String taskId) =>
      _get(IsarTaskDataType.pausedTask, taskId);

  @override
  Future<List<Task>> retrieveAllPausedTasks() =>
      _getAll(IsarTaskDataType.pausedTask);

  @override
  Future<void> removePausedTask(String? taskId) =>
      _remove(IsarTaskDataType.pausedTask, taskId);

  @override
  Future<void> storeResumeData(ResumeData resumeData) =>
      _store(IsarTaskDataType.resumeData, resumeData.taskId, resumeData);

  @override
  Future<ResumeData?> retrieveResumeData(String taskId) =>
      _get(IsarTaskDataType.resumeData, taskId);

  @override
  Future<List<ResumeData>> retrieveAllResumeData() =>
      _getAll(IsarTaskDataType.resumeData);

  @override
  Future<void> removeResumeData(String? taskId) =>
      _remove(IsarTaskDataType.resumeData, taskId);

  @override
  (String, int) get currentDatabaseVersion => ("FinampIsar", 1);

  @override
  // This should come from finamp settings if migration needed
  Future<(String, int)> get storedDatabaseVersion =>
      Future.value(("FinampIsar", 1));

  @override
  Future<void> initialize() async {
    // Isar database gets opened by main
  }

  Future<void> _store(IsarTaskDataType type, String id, dynamic data) async {
    type.check(data); // Verify the data object has the correct type
    String json = jsonEncode(data.toJson());
    _isar.writeTxnSync(() {
      _isar.isarTaskDatas
          .putSync(IsarTaskData(IsarTaskData.getHash(type, id), type, json, 0));
    });
  }

  Future<T?> _get<T>(IsarTaskDataType<T> type, String id) async {
    var item = await _isar.isarTaskDatas.get(IsarTaskData.getHash(type, id));
    return (item == null) ? null : type.fromJson(jsonDecode(item.jsonData));
  }

  Future<List<T>> _getAll<T>(IsarTaskDataType<T> type) async {
    var items = await _isar.isarTaskDatas.where().typeEqualTo(type).findAll();
    return items.map((e) => type.fromJson(jsonDecode(e.jsonData))).toList();
  }

  Future<void> _remove(IsarTaskDataType type, String? id) async {
    _isar.writeTxnSync(() {
      if (id != null) {
        _isar.isarTaskDatas.deleteSync(IsarTaskData.getHash(type, id));
      } else {
        _isar.isarTaskDatas.where().typeEqualTo(type).deleteAllSync();
      }
    });
  }
}

/// A wrapper for storing various types of download related data in isar as JSON.
/// Do not confuse the id of this type with the ids that the content types have.
/// They will not match.
@collection
class IsarTaskData<T> {
  IsarTaskData(this.id, this.type, this.jsonData, this.age);
  final Id id;
  String jsonData;
  @Enumerated(EnumType.ordinal)
  @Index()
  final IsarTaskDataType<T> type;
  // This allows prioritization and uniqueness checking by delete buffer
  final int age;

  static int globalAge = 0;

  IsarTaskData.build(String stringId, this.type, T data, {int? age})
      : id = IsarTaskData.getHash(type, stringId),
        jsonData = _toJson(data),
        age = age ?? globalAge++;

  static int getHash(IsarTaskDataType type, String id) {
    return _fastHash(type.name + id);
  }

  @ignore
  T get data => type.fromJson(jsonDecode(jsonData));
  set data(T item) => jsonData = _toJson(item);

  static String _toJson(dynamic item) {
    switch (item) {
      case int id:
        return jsonEncode({"id": id});
      case (int itemIsarId, bool required, String? viewId):
        return jsonEncode(
            {"stubId": itemIsarId, "required": required, "view": viewId});
      case _:
        return jsonEncode((item as dynamic).toJson());
    }
  }

  /// FNV-1a 64bit hash algorithm optimized for Dart Strings
  /// Provided by Isar documentation
  static int _fastHash(String string) {
    var hash = 0xcbf29ce484222325;

    var i = 0;
    while (i < string.length) {
      final codeUnit = string.codeUnitAt(i++);
      hash ^= codeUnit >> 8;
      hash *= 0x100000001b3;
      hash ^= codeUnit & 0xFF;
      hash *= 0x100000001b3;
    }

    return hash;
  }

  @override
  bool operator ==(Object other) {
    return other is IsarTaskData && other.id == id;
  }

  @override
  @ignore
  int get hashCode => id;
}

/// Type enum for IsarTaskData
/// Enumerated by Isar, do not modify existing entries.
enum IsarTaskDataType<T> {
  pausedTask<Task>(Task.createFromJson),
  taskRecord<TaskRecord>(TaskRecord.fromJson),
  resumeData<ResumeData>(ResumeData.fromJson),
  deleteNode<int>(_deleteFromJson),
  syncNode<(int, bool, String?)>(_syncFromJson);

  const IsarTaskDataType(this.fromJson);

  static int _deleteFromJson(Map<String, dynamic> map) {
    return map["id"];
  }

  static (int, bool, String?) _syncFromJson(Map<String, dynamic> map) {
    return (map["stubId"], map["required"], map["view"]);
  }

  final T Function(Map<String, dynamic>) fromJson;
  void check(T data) {}
}

/// This is a TaskQueue for FileDownloader that enqueues DownloadItems that are in
/// enqueued state.They should already have the file path calculated.
class IsarTaskQueue implements TaskQueue {
  static final _enqueueLog = Logger('IsarTaskQueue');
  final IsarDownloads _isarDownloads;
  final _jellyfinApiData = GetIt.instance<JellyfinApiHelper>();
  final _finampUserHelper = GetIt.instance<FinampUserHelper>();

  IsarTaskQueue(this._isarDownloads);

  /// Set of tasks that are believed to be actively running
  final _activeDownloads = <int>{}; // by TaskId

  Completer<void>? _callbacksComplete;

  final _isar = GetIt.instance<Isar>();

  /// Initialize the queue and start stored downloads.
  /// Should only be called after background_downloader and IsarDownloads are
  /// fully set up.
  Future<void> initializeQueue() async {
    _activeDownloads.addAll(
        (await FileDownloader().allTasks(includeTasksWaitingToRetry: true))
            .map((e) => int.parse(e.taskId)));
    FinampSettingsHelper.finampSettingsListener.addListener(() {
      if (!FinampSettingsHelper.finampSettings.isOffline) {
        executeDownloads();
      }
    });
    List<DownloadItem> completed = [];
    List<DownloadItem> needsEnqueue = [];
    // TODO batch this incase someone has a giant downloads list?
    for (var item in _isar.downloadItems
        .where()
        .stateEqualTo(DownloadItemState.enqueued)
        .or()
        .stateEqualTo(DownloadItemState.downloading)
        .filter()
        .typeEqualTo(DownloadItemType.song)
        .or()
        .typeEqualTo(DownloadItemType.image)
        .findAllSync()) {
      if (item.file?.existsSync() ?? false) {
        _activeDownloads.remove(item.isarId);
        completed.add(item);
      } else if (item.state == DownloadItemState.downloading) {
        if (!_activeDownloads.contains(item.isarId)) {
          needsEnqueue.add(item);
        }
      }
    }
    _isar.writeTxnSync(() {
      for (var item in completed) {
        _isarDownloads.updateItemState(item, DownloadItemState.complete);
      }
      for (var item in needsEnqueue) {
        _isarDownloads.updateItemState(item, DownloadItemState.enqueued);
      }
    });
  }

  /// Execute all pending downloads.
  Future<void> executeDownloads() async {
    if (_callbacksComplete != null) {
      return _callbacksComplete!.future;
    }
    try {
      _callbacksComplete = Completer();
      unawaited(_advanceQueue());
      await _callbacksComplete!.future;
    } finally {
      _callbacksComplete = null;
    }
  }

  /// Advance the queue if possible and ready, no-op if not.
  /// Will loop until all downloads have been enqueued.  Will enqueue
  /// finampSettings.maxConcurrentDownloads at once.
  Future<void> _advanceQueue() async {
    try {
      while (true) {
        var nextTasks = _isar.downloadItems
            .where()
            .stateEqualTo(DownloadItemState.enqueued)
            .filter()
            .allOf(_activeDownloads,
                (q, element) => q.not().isarIdEqualTo(element))
            .limit(20)
            .findAllSync();
        if (nextTasks.isEmpty ||
            !_isarDownloads.allowDownloads ||
            FinampSettingsHelper.finampSettings.isOffline) {
          return;
        }
        final tokenHeader = _jellyfinApiData.getTokenHeader();
        for (var task in nextTasks) {
          if (task.file == null) {
            _enqueueLog
                .severe("Recieved ${task.name} with no valid file path.");
            _isar.writeTxnSync(() {
              _isarDownloads.updateItemState(task, DownloadItemState.failed);
            });
            continue;
          }
          while (_activeDownloads.length >=
              FinampSettingsHelper.finampSettings.maxConcurrentDownloads) {
            await Future.delayed(const Duration(milliseconds: 500));
          }
          _activeDownloads.add(task.isarId);
          // Base URL shouldn't be null at this point (user has to be logged in
          // to get to the point where they can add downloads).
          var url = switch (task.type) {
            DownloadItemType.song =>
              "${_finampUserHelper.currentUser!.baseUrl}/Items/${task.id}/File",
            DownloadItemType.image => _jellyfinApiData
                .getImageUrl(
                  item: task.baseItem!,
                  // Download original file
                  quality: null,
                  format: null,
                )
                .toString(),
            _ => throw StateError("???"),
          };
          bool success = await FileDownloader().enqueue(DownloadTask(
              taskId: task.isarId.toString(),
              url: url,
              requiresWiFi:
                  FinampSettingsHelper.finampSettings.requireWifiForDownloads,
              displayName: task.name,
              baseDirectory: task.downloadLocation!.baseDirectory.baseDirectory,
              retries: 3,
              directory: path_helper.dirname(task.path!),
              headers: {
                if (tokenHeader != null) "X-Emby-Token": tokenHeader,
              },
              filename: path_helper.basename(task.path!)));
          if (!success) {
            // We currently have no way to recover here.  The user must re-sync to clear
            // the stuck download.
            _enqueueLog.severe(
                "Task ${task.name} failed to enqueue with background_downloader.");
          }
          await Future.delayed(const Duration(milliseconds: 20));
        }
      }
    } finally {
      _callbacksComplete?.complete();
    }
  }

  /// Returns true if the internal queue state and downloader state match
  /// the state of the given item.  Download state should be reset if false.
  Future<bool> validateQueued(DownloadItem item) async {
    var activeTasks =
        await FileDownloader().allTasks(includeTasksWaitingToRetry: true);
    var activeItemIds = activeTasks.map((e) => int.parse(e.taskId)).toList();
    if (item.state == DownloadItemState.downloading &&
        !activeItemIds.contains(item.isarId)) {
      return false;
    }
    if (_activeDownloads.contains(item.isarId) &&
        !activeItemIds.contains(item.isarId)) {
      return false;
    }
    return true;
  }

  /// Remove a download task from this queue and cancel any active download.
  Future<void> remove(DownloadItem item) async {
    if (item.state == DownloadItemState.enqueued) {
      _isar.writeTxnSync(() {
        var canonItem = _isar.downloadItems.getSync(item.isarId);
        if (canonItem != null) {
          _isarDownloads.updateItemState(
              canonItem, DownloadItemState.notDownloaded);
        }
      });
    }
    if (_activeDownloads.contains(item.isarId)) {
      _activeDownloads.remove(item.isarId);
      await FileDownloader().cancelTaskWithId(item.isarId.toString());
    }
  }

  /// Called by FileDownloader whenever a download completes.
  /// Remove the completed task and advance the queue.
  @override
  void taskFinished(Task task) {
    _activeDownloads.remove(int.parse(task.taskId));
  }
}

/// A class for storing pending deletes in Isar.  This is used to save unlinked
/// but not yet deleted nodes so that they always get cleaned up, even if the
/// app suddenly shuts down.
class IsarDeleteBuffer {
  final _isar = GetIt.instance<Isar>();
  final IsarDownloads _isarDownloads;
  final _deleteLogger = Logger("DeleteBuffer");

  final Set<int> _activeDeletes = {};
  Completer<void>? _callbacksComplete;

  IsarDeleteBuffer(this._isarDownloads) {
    IsarTaskData.globalAge = _isar.isarTaskDatas
            .where()
            .typeEqualTo(type)
            .sortByAgeDesc()
            .findFirstSync()
            ?.age ??
        0;
  }

  final type = IsarTaskDataType.deleteNode;

  final int _batchSize = 10;

  /// Add nodes to be deleted at a later time.  This should
  /// be called before nodes are unlinked to guarantee nodes cannot be lost.
  /// This should only be called inside an isar write transaction
  void addAll(Iterable<int> isarIds) {
    var items =
        isarIds.map((e) => IsarTaskData.build(e.toString(), type, e)).toList();
    _isar.isarTaskDatas.putAllSync(items);
  }

  /// Execute all pending deletes.
  Future<void> executeDeletes() async {
    if (_callbacksComplete != null) {
      return _callbacksComplete!.future;
    }
    try {
      _activeDeletes.clear();
      _callbacksComplete = Completer();
      unawaited(_advanceQueue());
      await _callbacksComplete!.future;
    } finally {
      _callbacksComplete = null;
    }
  }

  /// Execute all queued _syncdeletes.  Will call itself until there are max concurrent
  /// download workers running at once.  Uses age variable to determine if queued
  /// deletes have ben updated to avoid removing queue items that have been re-added
  /// and need re-calculation.
  Future<void> _advanceQueue() async {
    List<IsarTaskData<dynamic>> wrappedDeletes = [];
    while (true) {
      if (_activeDeletes.length >=
              FinampSettingsHelper.finampSettings.downloadWorkers *
                  _batchSize ||
          _callbacksComplete == null) {
        return;
      }
      try {
        // This must be synchronous or we can get more than 5 threads and multiple threads
        // processing the same item
        wrappedDeletes = _isar.isarTaskDatas
            .where()
            .typeEqualTo(type)
            .filter()
            .allOf(_activeDeletes, (q, value) => q.not().idEqualTo(value))
            .sortByAge() // Try to process oldest deletes first as they are more likely to be deletable
            .limit(_batchSize)
            .findAllSync();
        if (wrappedDeletes.isEmpty) {
          assert(_isar.isarTaskDatas.where().typeEqualTo(type).countSync() >=
              _activeDeletes.length);
          if (_activeDeletes.isEmpty && _callbacksComplete != null) {
            _callbacksComplete!.complete(null);
          }
          return;
        }
        _activeDeletes.addAll(wrappedDeletes.map((e) => e.id));
        // Once we've claimed our item, try to launch another worker in case we have <5.
        unawaited(_advanceQueue());
        for (var delete in wrappedDeletes) {
          try {
            await Future.wait([
              syncDelete(delete.data),
              Future.delayed(_isarDownloads.fullSpeedSync
                  ? const Duration(milliseconds: 200)
                  : const Duration(milliseconds: 1000))
            ]);
          } catch (e) {
            // we don't expect errors here, _syncDelete should already be catching everything
            // mark node as complete and continue
            GlobalSnackbar.error(e);
          }
        }

        _isar.writeTxnSync(() {
          var canonDeletes = _isar.isarTaskDatas
              .getAllSync(wrappedDeletes.map((e) => e.id).toList());
          List<int> removable = [];
          // Items with unexpected ages have been re-added and need reprocessing
          for (int i = 0; i < canonDeletes.length; i++) {
            if (wrappedDeletes[i].age == canonDeletes[i]?.age) {
              removable.add(wrappedDeletes[i].id);
            }
          }
          _isar.isarTaskDatas.deleteAllSync(removable);
        });
      } finally {
        var currentIds = wrappedDeletes.map((e) => e.id);
        _activeDeletes.removeAll(currentIds);
      }
    }
  }

  /// This processes a node for potential deletion based on incoming info and requires links.
  /// Required nodes will not be altered.  Info song nodes will have downloaded files
  /// deleted and info links cleared.  Other types of info node will have requires links
  /// cleared.  Nodes with no incoming links at all are deleted.  All unlinked children
  /// are added to delete buffer fro recursive sync deleting.
  Future<void> syncDelete(int isarId) async {
    DownloadItem? canonItem;
    int requiredByCount = -1;
    int infoForCount = -1;
    _isar.txnSync(() {
      canonItem = _isar.downloadItems.getSync(isarId);
      requiredByCount = canonItem?.requiredBy.filter().countSync() ?? -1;
      infoForCount = canonItem?.infoFor.filter().countSync() ?? -1;
    });
    _deleteLogger.finer("Sync deleting ${canonItem?.name ?? isarId}");
    if (canonItem == null ||
        requiredByCount > 0 ||
        canonItem!.type == DownloadItemType.anchor) {
      return;
    }
    // images should always be downloaded, even if they only have info links
    // This allows deleting all require links for collections but retaining associated images
    if (canonItem!.type == DownloadItemType.image && infoForCount > 0) {
      return;
    }

    if (canonItem!.type.hasFiles) {
      await deleteDownload(canonItem!);
    }

    Set<int> childIds = {};
    _isar.writeTxnSync(() {
      DownloadItem? transactionItem =
          _isar.downloadItems.getSync(canonItem!.isarId);
      if (transactionItem == null) {
        return;
      }
      if (transactionItem.type.hasFiles) {
        if (transactionItem.state != DownloadItemState.notDownloaded) {
          _deleteLogger.severe(
              "Could not delete ${transactionItem.name}, may still have files");
          return;
        }
      }
      infoForCount = transactionItem.infoFor.filter().countSync();
      requiredByCount = transactionItem.requiredBy.filter().countSync();
      if (requiredByCount != 0) {
        _deleteLogger.severe(
            "Node ${transactionItem.id} became required during file deletion");
        return;
      }
      if (infoForCount > 0) {
        if (transactionItem.type == DownloadItemType.song) {
          // Non-required songs cannot have info links to collections, but they
          // can still require their images.
          childIds.addAll(
              transactionItem.info.filter().isarIdProperty().findAllSync());
          addAll(childIds);
          transactionItem.info.resetSync();
        } else {
          childIds.addAll(
              transactionItem.requires.filter().isarIdProperty().findAllSync());
          addAll(childIds);
          transactionItem.requires.resetSync();
        }
      } else {
        childIds.addAll(
            transactionItem.info.filter().isarIdProperty().findAllSync());
        childIds.addAll(
            transactionItem.requires.filter().isarIdProperty().findAllSync());
        addAll(childIds);
        _isar.downloadItems.deleteSync(transactionItem.isarId);
      }
    });
  }

  /// Removes any files associated with the item, cancels any pending downloads,
  /// and marks it as notDownloaded.  Used by [_syncDelete], as well as by
  /// [repairAllDownloads] and [_initiateDownload] to force a file into a known state.
  Future<void> deleteDownload(DownloadItem item) async {
    assert(item.type.hasFiles);
    if (item.state == DownloadItemState.notDownloaded) {
      return;
    }

    await _isarDownloads.downloadTaskQueue.remove(item);
    if (item.file != null) {
      try {
        await item.file!.delete();
      } on PathNotFoundException {
        _deleteLogger.finer(
            "File ${item.file!.path} for ${item.name} missing during delete.");
      }
    }

    if (item.file != null && item.downloadLocation!.useHumanReadableNames) {
      Directory songDirectory = item.file!.parent;
      try {
        if (await songDirectory.list().isEmpty) {
          _deleteLogger.info("${songDirectory.path} is empty, deleting");
          await songDirectory.delete();
        }
      } on PathNotFoundException {
        _deleteLogger
            .finer("Directory ${songDirectory.path} missing during delete.");
      }
    }

    _isar.writeTxnSync(() {
      var transactionItem = _isar.downloadItems.getSync(item.isarId);
      if (transactionItem != null) {
        _isarDownloads.updateItemState(
            transactionItem, DownloadItemState.notDownloaded);
      }
    });
  }
}

/// A class for storing pending syncs in Isar.  This allows syncing to resume
/// in the event of an app shutdown.  Completed lists are stored in memory,
/// so some nodes may get re-synced unnecessarily after an unexpected reboot
/// but this should have minimal impact.
class IsarSyncBuffer {
  final _isar = GetIt.instance<Isar>();
  final IsarDownloads _isarDownloads;
  final _syncLogger = Logger("SyncBuffer");
  final _jellyfinApiData = GetIt.instance<JellyfinApiHelper>();

  /// Currently processing syncs.  Will be null if no syncs are executing.
  final Set<int> _activeSyncs = {};
  final Set<int> _requireCompleted = {};
  final Set<int> _infoCompleted = {};
  Completer<void>? _callbacksComplete;

  final int _batchSize = 10;

  IsarSyncBuffer(this._isarDownloads);

  final type = IsarTaskDataType.syncNode;

  /// Add nodes to be synced at a later time.
  /// Must be called inside an Isar write transaction.
  void addAll(Iterable<DownloadStub> required, Iterable<DownloadStub> info,
      String? viewId) {
    var items = required
        .map((e) => IsarTaskData.build(
            "required ${e.isarId}", type, (e.isarId, true, viewId),
            age: 0))
        .toList();
    items.addAll(info.map((e) => IsarTaskData.build(
        "info ${e.isarId}", type, (e.isarId, false, viewId),
        age: 1)));
    _isar.isarTaskDatas.putAllSync(items);
  }

  /// Execute all pending syncs.
  Future<void> executeSyncs() async {
    if (_callbacksComplete != null) {
      return _callbacksComplete!.future;
    }
    try {
      _requireCompleted.clear();
      _infoCompleted.clear();
      _activeSyncs.clear();
      _metadataCache = {};
      _childCache = {};
      _callbacksComplete = Completer();
      unawaited(_advanceQueue());
      await _callbacksComplete!.future;
    } finally {
      _callbacksComplete = null;
    }
  }

  /// Execute all queued _syncDownload.  Will call itself until there are max concurrent
  /// download workers running at once.  Will retry items that throw errors up to
  /// 5 times before skipping and alerting the user.
  Future<void> _advanceQueue() async {
    List<IsarTaskData<dynamic>> wrappedSyncs = [];
    while (true) {
      if ((_isarDownloads.fullSpeedSync
                  ? _activeSyncs.length
                  : (_activeSyncs.length * 3)) >=
              FinampSettingsHelper.finampSettings.downloadWorkers *
                  _batchSize ||
          _callbacksComplete == null) {
        return;
      }
      try {
        // This must be synchronous or we can get more than 5 threads and multiple threads
        // processing the same item
        wrappedSyncs = _isar.isarTaskDatas
            .where()
            .typeEqualTo(type)
            .filter()
            .allOf(_activeSyncs, (q, value) => q.not().idEqualTo(value))
            .sortByAge() // Prioritize required nodes
            .limit(_batchSize)
            .findAllSync();
        if (wrappedSyncs.isEmpty ||
            !_isarDownloads.allowDownloads ||
            FinampSettingsHelper.finampSettings.isOffline) {
          assert(_isar.isarTaskDatas.where().typeEqualTo(type).countSync() >=
              _activeSyncs.length);
          if (_activeSyncs.isEmpty && _callbacksComplete != null) {
            _callbacksComplete!.complete(null);
          }
          return;
        }
        _activeSyncs.addAll(wrappedSyncs.map((e) => e.id));
        // Once we've claimed our item, try to launch another worker in case we have <5.
        unawaited(_advanceQueue());
        List<IsarTaskData<dynamic>> failedSyncs = [];
        for (var wrappedSync in wrappedSyncs) {
          var sync = wrappedSync.data;
          try {
            var item = _isar.downloadItems.getSync(sync.$1);
            if (item != null) {
              var timer = Future.delayed(const Duration(milliseconds: 50));
              try {
                await _syncDownload(
                    item, sync.$2, _requireCompleted, _infoCompleted, sync.$3);
              } catch (_) {
                // Re-enqueue failed syncs with lower priority
                if (wrappedSync.age > 10) {
                  throw "Repeatedly failed to sync ${item.name}";
                } else {
                  failedSyncs.add(IsarTaskData(wrappedSync.id, wrappedSync.type,
                      wrappedSync.jsonData, wrappedSync.age + 2));
                }
              }
              await timer;
            }
          } catch (e) {
            // mark node as complete and continue
            GlobalSnackbar.error(e);
          }
        }

        _isar.writeTxnSync(() {
          _isar.isarTaskDatas
              .deleteAllSync(wrappedSyncs.map((e) => e.id).toList());
          _isar.isarTaskDatas.putAllSync(failedSyncs);
        });
      } finally {
        _activeSyncs.removeAll(wrappedSyncs.map((e) => e.id));
      }
    }
  }

  /// Syncs a downloaded item with the latest data from the server, then recursively
  /// syncs children.  The item should already be present in Isar.  Items can be synced
  /// as required or info.  Info collections will only have info child nodes, and info
  /// songs will only have required nodes.  Info songs will not be downloaded.
  /// Image/anchor nodes always process as required, so this flag has no effect.  Nodes
  /// processed as info may be required via another parent, so children/files only needed
  /// for required nodes should be left in place, and will be handled by [_syncDelete]
  /// if necessary.  See [repairAllDownloads] for more information on the structure
  /// of the node graph and which children are allowable for each node type.
  Future<void> _syncDownload(DownloadStub parent, bool asRequired,
      Set<int> requireCompleted, Set<int> infoCompleted, String? viewId) async {
    if (parent.type == DownloadItemType.image ||
        parent.type == DownloadItemType.anchor) {
      asRequired = true; // Always download images, don't process twice.
    }
    if (parent.type == DownloadItemType.collection) {
      if (parent.baseItemType == BaseItemDtoType.playlist) {
        // Playlists show in all libraries, do not apply library info
        viewId = null;
      } else if (parent.baseItemType == BaseItemDtoType.library) {
        // Update view id for children of downloaded library
        viewId = parent.id;
      }
    }
    if (requireCompleted.contains(parent.isarId)) {
      return;
    } else if (infoCompleted.contains(parent.isarId) && !asRequired) {
      return;
    } else {
      if (asRequired) {
        requireCompleted.add(parent.isarId);
      } else {
        infoCompleted.add(parent.isarId);
      }
    }

    // TODO try to find a way to not add existing playlist songs to sync queue
    // Skip items that are unlikely to need syncing if allowed.
    if (FinampSettingsHelper.finampSettings.preferQuickSyncs &&
        !_isarDownloads.forceFullSync) {
      if (parent.type == DownloadItemType.song ||
          parent.type == DownloadItemType.image ||
          (parent.type == DownloadItemType.collection &&
              parent.baseItemType == BaseItemDtoType.album)) {
        var item = _isar.downloadItems.getSync(parent.isarId);
        if (item?.state == DownloadItemState.complete) {
          _syncLogger.finest("Skipping sync of ${parent.name}");
          return;
        }
      }
    }

    _syncLogger.finer(
        "Syncing ${parent.name} with required:$asRequired viewId:$viewId");

    //
    // Calculate needed children for item based on type and asRequired flag
    //
    bool updateChildren = true;
    Set<DownloadStub> requiredChildren = {};
    Set<DownloadStub> infoChildren = {};
    List<DownloadStub>? orderedChildItems;
    switch (parent.type) {
      case DownloadItemType.collection:
        var item = parent.baseItem!;
        // TODO alert user that image deduplication is broken.
        if ((item.blurHash ?? item.imageId) != null) {
          infoChildren.add(
              DownloadStub.fromItem(type: DownloadItemType.image, item: item));
        }
        try {
          if (asRequired) {
            orderedChildItems = await _getCollectionChildren(parent);
            requiredChildren.addAll(orderedChildItems);
          }
          if (parent.baseItemType == BaseItemDtoType.album ||
              parent.baseItemType == BaseItemDtoType.playlist) {
            orderedChildItems ??= await _getCollectionChildren(parent);
            infoChildren.addAll(orderedChildItems);
          }
        } catch (e) {
          _syncLogger.info("Error downloading children for ${item.name}: $e");
          rethrow;
        }
      case DownloadItemType.song:
        var item = parent.baseItem!;
        if ((item.blurHash ?? item.imageId) != null) {
          requiredChildren.add(
              DownloadStub.fromItem(type: DownloadItemType.image, item: item));
        }
        if (asRequired) {
          List<String> collectionIds = [];
          collectionIds.addAll(item.genreItems?.map((e) => e.id) ?? []);
          collectionIds.addAll(item.artistItems?.map((e) => e.id) ?? []);
          collectionIds.addAll(item.albumArtists?.map((e) => e.id) ?? []);
          if (item.albumId != null) {
            collectionIds.add(item.albumId!);
          }
          try {
            var collectionChildren =
                await Future.wait(collectionIds.map(_getCollectionInfo));
            infoChildren.addAll(collectionChildren.whereNotNull());
          } catch (e) {
            _syncLogger
                .info("Failed to download metadata for ${item.name}: $e");
            rethrow;
          }
        }
      case DownloadItemType.image:
        break;
      case DownloadItemType.anchor:
        var oldChildren = _isar.downloadItems
            .filter()
            .requiredBy((q) => q.isarIdEqualTo(parent.isarId))
            .findAllSync();
        if (_isarDownloads.hardSyncMetadata) {
          List<DownloadStub?> newChildren =
              await Future.wait(oldChildren.map((e) {
            try {
              return _jellyfinApiData.getItemByIdBatched(e.id).then((value) =>
                  value == null
                      ? null
                      : DownloadStub.fromItem(item: value, type: e.type));
            } catch (e) {
              return Future.error(e);
            }
          }));
          requiredChildren.addAll(newChildren.whereNotNull());
        } else {
          requiredChildren.addAll(oldChildren);
        }
        updateChildren = false;
      case DownloadItemType.finampCollection:
        try {
          if (asRequired) {
            orderedChildItems = await _getFinampCollectionChildren(parent);
            requiredChildren.addAll(orderedChildItems);
          }
        } catch (e) {
          _syncLogger.info(
              "Error downloading children for finampCollection ${parent.name}: $e");
          rethrow;
        }
    }

    //
    // Update item with latest metadata and previously calculated children.
    // If calculating children previously failed, just fetch current children.
    //
    DownloadLocation? downloadLocation;
    DownloadItem? canonParent;
    if (updateChildren) {
      _isar.writeTxnSync(() {
        canonParent = _isar.downloadItems.getSync(parent.isarId);
        if (canonParent == null) {
          throw StateError("_syncDownload called on missing node ${parent.id}");
        }
        try {
          var newParent = canonParent!.copyWith(
              // We expect the parent baseItem to be more up to date as it recently came from
              // the server via the online UI or _getCollectionChildren.  It may also be from
              // Isar via _getCollectionInfo, in which case this is a no-op.
              item: parent.baseItem,
              viewId: viewId,
              orderedChildItems: orderedChildItems);
          if (newParent != null) {
            _isar.downloadItems.putSync(newParent);
            canonParent = newParent;
          }
        } catch (e) {
          _syncLogger.warning(e);
        }

        downloadLocation = canonParent!.downloadLocation;
        viewId ??= canonParent!.viewId;

        if (asRequired) {
          _updateChildren(canonParent!, true, requiredChildren);
          _updateChildren(canonParent!, false, infoChildren);
        } else if (canonParent!.type == DownloadItemType.song) {
          // For info only songs, we put image link into required so that we can delete
          // all info links in _syncDelete, so if not processing as required only
          // update that and ignore info links
          _updateChildren(canonParent!, true, requiredChildren);
        } else {
          _updateChildren(canonParent!, false, infoChildren);
        }
        addAll(requiredChildren, infoChildren.difference(requiredChildren),
            viewId);
      });
    } else {
      _isar.writeTxnSync(() {
        addAll(requiredChildren, infoChildren.difference(requiredChildren),
            viewId);
      });
    }

    //
    // Download item files if needed
    //
    if (canonParent!.type.hasFiles && asRequired) {
      if (downloadLocation == null) {
        _syncLogger.severe(
            "could not download ${parent.id}, no download location found.");
      } else {
        await _initiateDownload(canonParent!, downloadLocation!);
      }
    }
  }

  /// This updates the children of an item to exactly match the given set.
  /// Children not currently present in Isar are added.  Unlinked items
  /// are added to delete buffer to later have [_syncDelete] run on them.
  /// links argument should be parent.info or parent.requires.
  /// Used within [_syncDownload].
  /// This should only be called inside an isar write transaction.
  void _updateChildren(
      DownloadItem parent, bool required, Set<DownloadStub> children) {
    IsarLinks<DownloadItem> links = required ? parent.requires : parent.info;

    var oldChildIds = (links.filter().isarIdProperty().findAllSync()).toSet();
    var newChildIds = children.map((e) => e.isarId).toSet();
    var childIdsToUnlink = oldChildIds.difference(newChildIds);
    var missingChildIds = newChildIds.difference(oldChildIds);
    var childrenToUnlink =
        (_isar.downloadItems.getAllSync(childIdsToUnlink.toList()))
            .whereNotNull()
            .toList();
    // anyOf filter allows all objects when given empty list, but we want no objects
    var childIdsToLink = (missingChildIds.isEmpty)
        ? <int>[]
        : _isar.downloadItems
            .where()
            .anyOf(missingChildIds, (q, int id) => q.isarIdEqualTo(id))
            .isarIdProperty()
            .findAllSync();
    // This is only used for IsarLink.update, which only cares about ID, so stubs are fine
    var childrenToLink = children
        .where((element) => childIdsToLink.contains(element.isarId))
        .map((e) => e.asItem(parent.downloadLocationId))
        .toList();
    var childrenToPutAndLink = children
        .where((element) =>
            missingChildIds.contains(element.isarId) &&
            !childIdsToLink.contains(element.isarId))
        .map((e) => e.asItem(parent.downloadLocationId))
        .toList();
    assert(childIdsToLink.length + childrenToPutAndLink.length ==
        missingChildIds.length);
    assert(
        missingChildIds.length + oldChildIds.length - childrenToUnlink.length ==
            children.length);
    _isar.downloadItems.putAllSync(childrenToPutAndLink);
    _isarDownloads.deleteBuffer.addAll(childrenToUnlink.map((e) => e.isarId));
    if (missingChildIds.isNotEmpty || childrenToUnlink.isNotEmpty) {
      links.updateSync(
          link: childrenToLink + childrenToPutAndLink,
          unlink: childrenToUnlink);
      // Collection download state may need changing with different children
      return _isarDownloads.syncItemState(parent);
    }
  }

  /// Get BaseItemDto from the given collection ID.  Tries local cache, then
  /// Isar, then requests data from jellyfin in a batch with other calls
  /// to this method.  Used within [_syncDownload].
  Future<DownloadStub?> _getCollectionInfo(String id) async {
    if (_metadataCache.containsKey(id)) {
      return _metadataCache[id];
    }
    Completer<DownloadStub> itemFetch = Completer();
    try {
      _metadataCache[id] = itemFetch.future;

      DownloadStub? item;
      if (!_isarDownloads.hardSyncMetadata) {
        item = _isar.downloadItems
            .getSync(DownloadStub.getHash(id, DownloadItemType.collection));
      }
      if (item == null) {
        item = await _jellyfinApiData.getItemByIdBatched(id).then((value) =>
            value == null
                ? null
                : DownloadStub.fromItem(
                    item: value, type: DownloadItemType.collection));
        _isarDownloads.resetConnectionErrors();
      }
      itemFetch.complete(item);
      return itemFetch.future;
    } catch (e) {
      itemFetch.completeError(e);
      _isarDownloads.incrementConnectionErrors();
      return itemFetch.future;
    }
  }

  Future<void> _childThrottle = Future.value();
  Future<void> _nextChildThrottleSlot() async {
    var nextSlot = _childThrottle;
    _childThrottle = _childThrottle
        .then((value) => Future.delayed(_isarDownloads.fullSpeedSync
            // TODO this should probably respond to downloadWorkers
            ? const Duration(milliseconds: 300)
            : const Duration(milliseconds: 1000)));
    await nextSlot;
  }

  // These cache downloaded metadata during _syncDownload
  Map<String, Future<DownloadStub>> _metadataCache = {};
  Map<String, Future<List<BaseItemDto>>> _childCache = {};

  /// Get ordered child items for the given DownloadStub.  Tries local cache, then
  /// requests data from jellyfin.  This method throttles to three jellyfin calls
  /// per second across all invocations.  Used within [_syncDownload].
  Future<List<DownloadStub>> _getCollectionChildren(DownloadStub parent) async {
    DownloadItemType childType;
    BaseItemDtoType childFilter;
    String? fields;
    assert(parent.type == DownloadItemType.collection);
    switch (parent.baseItemType) {
      case BaseItemDtoType.playlist || BaseItemDtoType.album:
        childType = DownloadItemType.song;
        childFilter = BaseItemDtoType.song;
        fields = "${_jellyfinApiData.defaultFields},MediaSources";
      case BaseItemDtoType.artist ||
            BaseItemDtoType.genre ||
            BaseItemDtoType.library:
        childType = DownloadItemType.collection;
        childFilter = BaseItemDtoType.album;
      case _:
        throw StateError("Unknown collection type ${parent.baseItemType}");
    }
    var item = parent.baseItem!;

    if (_childCache.containsKey(item.id)) {
      var children = await _childCache[item.id]!;
      return children
          .map((e) => DownloadStub.fromItem(type: childType, item: e))
          .toList();
    }
    Completer<List<BaseItemDto>> itemFetch = Completer();
    // This prevents errors in itemFetch being reported as unhandled.
    // They are handled by original caller in rethrow.
    unawaited(itemFetch.future.then((_) => null, onError: (_) => null));
    try {
      _childCache[item.id] = itemFetch.future;
      await _nextChildThrottleSlot();
      var childItems = await _jellyfinApiData.getItems(
              parentItem: item,
              includeItemTypes: childFilter.idString,
              fields: fields) ??
          [];
      _isarDownloads.resetConnectionErrors();
      itemFetch.complete(childItems);
      return childItems
          .map((e) => DownloadStub.fromItem(type: childType, item: e))
          .toList();
    } catch (e) {
      _isarDownloads.incrementConnectionErrors();
      itemFetch.completeError(e);
      rethrow;
    }
  }

  Future<List<DownloadStub>> _getFinampCollectionChildren(
      DownloadStub parent) async {
    assert(parent.type == DownloadItemType.finampCollection);
    assert(parent.id == "Favorites");

    try {
      final childItems = await _jellyfinApiData.getItems(
            includeItemTypes: "Audio,MusicAlbum,Playlist",
            filters: "IsFavorite",
          ) ??
          [];
      // Artists use a different endpoint, so request those separately
      childItems.addAll(await _jellyfinApiData.getItems(
            includeItemTypes: "MusicArtist",
            filters: "IsFavorite",
          ) ??
          []);
      _isarDownloads.resetConnectionErrors();
      return childItems
          .map((e) => DownloadStub.fromItem(
              item: e,
              type: e.type == "Audio"
                  ? DownloadItemType.song
                  : DownloadItemType.collection))
          .toList();
    } catch (e) {
      _isarDownloads.incrementConnectionErrors();
      rethrow;
    }
  }

  /// Ensures the given node is downloaded.  Called on all required nodes with files
  /// by [_syncDownload].  Items enqueued/downloading/failed are validated and cleaned
  /// up before re-initiating download if needed.
  Future<void> _initiateDownload(
      DownloadItem item, DownloadLocation downloadLocation) async {
    switch (item.state) {
      case DownloadItemState.complete:
        return;
      case DownloadItemState.notDownloaded:
        break;
      case DownloadItemState.enqueued: //fall through
      case DownloadItemState.downloading:
        if (await _isarDownloads.downloadTaskQueue.validateQueued(item)) {
          return;
        }
        await _isarDownloads.deleteBuffer.deleteDownload(item);
      case DownloadItemState.failed:
        await _isarDownloads.deleteBuffer.deleteDownload(item);
    }

    switch (item.type) {
      case DownloadItemType.song:
        return _downloadSong(item, downloadLocation);
      case DownloadItemType.image:
        return _downloadImage(item, downloadLocation);
      case _:
        throw StateError("???");
    }
  }

  /// Removes unsafe characters from file names.  Used by [_downloadSong] and
  /// [_downloadImage] for human readable download locations.
  String? _filesystemSafe(String? unsafe) =>
      unsafe?.replaceAll(RegExp('[/?<>\\:*|"]'), "_");

  /// Creates a download task for the given song and adds it to the download queue.
  /// Also marks item as enqueued in isar.
  Future<void> _downloadSong(
      DownloadItem downloadItem, DownloadLocation downloadLocation) async {
    assert(downloadItem.type == DownloadItemType.song);
    var item = downloadItem.baseItem!;

    if (downloadItem.baseItem!.mediaSources == null &&
        FinampSettingsHelper.finampSettings.isOffline) {
      _isar.writeTxnSync(() {
        var canonItem = _isar.downloadItems.getSync(downloadItem.isarId);
        if (canonItem == null) {
          throw StateError(
              "Node missing while failing offline download for ${downloadItem.name}: $canonItem");
        }
        _isarDownloads.updateItemState(canonItem, DownloadItemState.failed);
      });
    }
    // We try to always fetch the mediaSources when getting album/playlist, but sometimes
    // we download/sync individual songs and need to fetch playback info here.
    List<MediaSourceInfo>? mediaSources = downloadItem.baseItem!.mediaSources ??
        (await _jellyfinApiData.getPlaybackInfo(item.id));

    String fileName;
    String subDirectory;
    if (downloadLocation.useHumanReadableNames) {
      if (mediaSources == null) {
        _syncLogger.warning(
            "Media source info for ${item.id} returned null, filename may be weird.");
      }
      subDirectory =
          path_helper.join("finamp", _filesystemSafe(item.albumArtist));
      // We use a regex to filter out bad characters from song/album names.
      fileName = _filesystemSafe(
          "${item.album} - ${item.indexNumber ?? 0} - ${item.name}.${mediaSources?[0].container ?? 'song'}")!;
    } else {
      fileName = "${item.id}.${mediaSources?[0].container ?? 'song'}";
      subDirectory = "songs";
    }

    if (downloadLocation.baseDirectory.needsPath) {
      subDirectory =
          path_helper.join(downloadLocation.currentPath, subDirectory);
    }

    _isar.writeTxnSync(() {
      DownloadItem? canonItem =
          _isar.downloadItems.getSync(downloadItem.isarId);
      if (canonItem == null) {
        _syncLogger.severe(
            "Download metadata ${downloadItem.id} missing after download starts");
        throw StateError("Could not save download task id");
      }
      canonItem.downloadLocationId = downloadLocation.id;
      canonItem.path = path_helper.join(subDirectory, fileName);
      if (canonItem.baseItem?.mediaSources == null && mediaSources != null) {
        var newBaseItem = canonItem.baseItem!;
        newBaseItem.mediaSources = mediaSources;
        canonItem = canonItem.copyWith(item: newBaseItem)!;
      }
      if (canonItem.state != DownloadItemState.notDownloaded) {
        _syncLogger.severe(
            "Song ${canonItem.name} changed state to ${canonItem.state} while initiating download.");
      } else {
        _isarDownloads.updateItemState(canonItem, DownloadItemState.enqueued,
            alwaysPut: true);
      }
    });
  }

  /// Creates a download task for the given image and adds it to the download queue.
  /// Also marks item as enqueued in isar.
  Future<void> _downloadImage(
      DownloadItem downloadItem, DownloadLocation downloadLocation) async {
    assert(downloadItem.type == DownloadItemType.image);
    var item = downloadItem.baseItem!;

    String subDirectory;
    if (downloadLocation.useHumanReadableNames) {
      subDirectory =
          path_helper.join("finamp", _filesystemSafe(item.albumArtist));
    } else {
      subDirectory = "images";
    }

    if (downloadLocation.baseDirectory.needsPath) {
      subDirectory =
          path_helper.join(downloadLocation.currentPath, subDirectory);
    }

    // We still use imageIds for filenames despite switching to blurhashes as
    // blurhashes can include characters that filesystems don't support
    final fileName = "${_filesystemSafe(item.imageId)!}.image";

    _isar.writeTxnSync(() {
      DownloadItem? canonItem =
          _isar.downloadItems.getSync(downloadItem.isarId);
      if (canonItem == null) {
        _syncLogger.severe(
            "Download metadata ${downloadItem.id} missing after download starts");
        throw StateError("Could not save download task id");
      }
      canonItem.downloadLocationId = downloadLocation.id;
      canonItem.path = path_helper.join(subDirectory, fileName);
      if (canonItem.state != DownloadItemState.notDownloaded) {
        _syncLogger.severe(
            "Image ${canonItem.name} changed state to ${canonItem.state} while initiating download.");
      } else {
        _isarDownloads.updateItemState(canonItem, DownloadItemState.enqueued,
            alwaysPut: true);
      }
    });
  }
}
