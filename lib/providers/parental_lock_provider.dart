import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/storage/parental_controls_store.dart';

/// Session + settings for parental PIN / hidden Live groups / sources.
///
/// PIN hash is device-local (secure storage). Hidden category and source ids
/// are profile-scoped prefs and are not included in Drive sync snapshots.
class ParentalLockProvider extends ChangeNotifier {
  ParentalLockProvider({required String profileId})
      : _store = ParentalControlsStore(profileId: profileId);

  ParentalControlsStore _store;
  bool _ready = false;
  bool _hasPin = false;
  bool _sessionUnlocked = false;
  bool _lockOnResume = false;
  bool _hideSourceAdult = true;
  Set<String> _hiddenCategoryIds = {};
  Set<String> _hiddenSourceIds = {};
  /// Category id → display name (for Live DB group_name filtering).
  Map<String, String> _hiddenIdToName = {};

  bool get ready => _ready;
  bool get hasPin => _hasPin;
  bool get sessionUnlocked => _sessionUnlocked;
  bool get lockOnResume => _lockOnResume;
  /// When locked, also hide items/categories with [MediaItem.isAdult] /
  /// [IptvCategory.isAdult] from the source.
  bool get hideSourceAdult => _hideSourceAdult;
  Set<String> get hiddenLiveCategoryIds => _hiddenCategoryIds;
  Set<String> get hiddenSourceIds => _hiddenSourceIds;

  /// Display names currently mapped for hidden category ids.
  List<String> get hiddenLiveGroupNames => [
        for (final name in _hiddenIdToName.values)
          if (name.trim().isNotEmpty) name.trim(),
      ];

  /// Cache / filter stamp that changes whenever lock state or hidden ids change.
  String get lockFilterStamp {
    if (!_ready) return 'pending';
    if (!isContentLocked) return 'unlocked';
    final ids = _hiddenCategoryIds.toList()..sort();
    final sources = _hiddenSourceIds.toList()..sort();
    final adult = _hideSourceAdult ? 'adult' : 'noadult';
    return 'locked|$adult|${ids.join(',')}|src:${sources.join(',')}';
  }

  /// True when locked content should be filtered from Live listings.
  ///
  /// Until [load] finishes, this is pessimistic so hidden groups never flash.
  bool get isContentLocked => !_ready || (_hasPin && !_sessionUnlocked);

  /// True when the whole app should show the unlock gate.
  bool get isAppLocked =>
      _ready && _hasPin && _lockOnResume && !_sessionUnlocked;

  Future<void> bindProfile(String profileId) async {
    _store = ParentalControlsStore(profileId: profileId);
    // Drop previous profile state synchronously so Live filters never briefly
    // apply the wrong PIN / hidden-id set during the async reload.
    _sessionUnlocked = false;
    _ready = false;
    _hasPin = false;
    _lockOnResume = false;
    _hideSourceAdult = true;
    _hiddenCategoryIds = {};
    _hiddenSourceIds = {};
    _hiddenIdToName = {};
    notifyListeners();
    await load();
  }

  Future<void> load() async {
    _hasPin = await _store.hasPin();
    _lockOnResume = await _store.loadLockOnResume();
    _hideSourceAdult = await _store.loadHideSourceAdult();
    final ids = await _store.loadHiddenLiveCategoryIds();
    _hiddenCategoryIds = ids.toSet();
    final sourceIds = await _store.loadHiddenSourceIds();
    _hiddenSourceIds = sourceIds.toSet();
    final names = await _store.loadHiddenLiveCategoryNames();
    _hiddenIdToName = {
      for (final e in names.entries)
        if (_hiddenCategoryIds.contains(e.key) && e.value.trim().isNotEmpty)
          e.key: e.value.trim(),
    };
    _ready = true;
    notifyListeners();
  }

  /// Keep name map in sync so group_name DB filters match category picks.
  void syncCategoryNames(List<IptvCategory> liveCategories) {
    final map = <String, String>{
      for (final e in _hiddenIdToName.entries)
        if (_hiddenCategoryIds.contains(e.key)) e.key: e.value,
    };
    for (final c in liveCategories) {
      if (!_hiddenCategoryIds.contains(c.id)) continue;
      final name = c.name.trim();
      if (name.isEmpty) continue;
      map[c.id] = name;
    }
    if (map.length == _hiddenIdToName.length &&
        map.entries.every((e) => _hiddenIdToName[e.key] == e.value)) {
      return;
    }
    _hiddenIdToName = map;
    // Prefs write failures must not block UI filters.
    unawaited(_store.saveHiddenLiveCategoryNames(_hiddenIdToName));
  }

  bool isCategoryIdHidden(String id) {
    if (!isContentLocked) return false;
    if (!_ready) return true;
    return _hiddenCategoryIds.contains(id);
  }

  /// True when locked and [sourceId] is in the parental hidden-sources set.
  bool isSourceIdHidden(String? sourceId) {
    if (!isContentLocked) return false;
    final id = sourceId?.trim();
    if (id == null || id.isEmpty) return false;
    // Until ready, hide every known source id so listings cannot leak.
    if (!_ready) return true;
    return _hiddenSourceIds.contains(id);
  }

  bool isGroupNameHidden(String? groupName) {
    if (!isContentLocked) return false;
    // Until ready, hide every named Live group so DB listings cannot leak.
    if (!_ready) return true;
    final g = groupName?.trim();
    if (g == null || g.isEmpty) return false;
    for (final name in _hiddenIdToName.values) {
      if (name.toLowerCase() == g.toLowerCase()) return true;
    }
    // Fallback: treat category id itself as a group key used by some sources.
    return _hiddenCategoryIds.contains(g);
  }

  bool isLiveChannelHidden(MediaItem channel) =>
      isSourceIdHidden(channel.sourceId) ||
      isGroupNameHidden(channel.group) ||
      isAdultItemHidden(channel);

  /// True when locked and [hideSourceAdult] and the item is source-marked adult.
  bool isAdultItemHidden(MediaItem item) {
    if (!isContentLocked) return false;
    if (!_ready) return true;
    if (!_hideSourceAdult) return false;
    return item.isAdult;
  }

  /// Live / VOD / catalog item should be filtered from locked listings.
  bool isItemHidden(MediaItem item) {
    if (isSourceIdHidden(item.sourceId)) return true;
    if (item.isLive) return isLiveChannelHidden(item);
    return isAdultItemHidden(item);
  }

  bool isAdultCategoryHidden(IptvCategory category) {
    if (!isContentLocked) return false;
    if (!_ready) return true;
    if (!_hideSourceAdult) return false;
    return category.isAdult;
  }

  List<IptvCategory> filterLiveCategories(List<IptvCategory> categories) {
    if (!_ready) return const [];
    if (!isContentLocked) return categories;
    return [
      for (final c in categories)
        if (!isSourceIdHidden(c.sourceId) &&
            !_hiddenCategoryIds.contains(c.id) &&
            !isGroupNameHidden(c.name) &&
            !_hiddenCategoryIds.contains(c.name.trim()) &&
            !isAdultCategoryHidden(c))
          c,
    ];
  }

  List<IptvCategory> filterCategories(List<IptvCategory> categories) {
    if (!_ready) return const [];
    if (!isContentLocked) return categories;
    return [
      for (final c in categories)
        if (!isSourceIdHidden(c.sourceId) && !isAdultCategoryHidden(c)) c,
    ];
  }

  Future<bool> unlock(String pin) async {
    final ok = await _store.verifyPin(pin);
    if (!ok) return false;
    _sessionUnlocked = true;
    notifyListeners();
    return true;
  }

  /// Verify without unlocking the session (change / clear PIN flows).
  Future<bool> verifyOnly(String pin) => _store.verifyPin(pin);

  void lockSession() {
    if (!_sessionUnlocked) return;
    _sessionUnlocked = false;
    notifyListeners();
  }

  /// Call from app lifecycle when returning from background / PiP.
  void onAppResumed() {
    if (_ready && _hasPin && _lockOnResume) {
      lockSession();
    }
  }

  Future<void> setPin(String pin) async {
    await _store.setPin(pin);
    _hasPin = true;
    _sessionUnlocked = true;
    notifyListeners();
  }

  Future<bool> changePin({
    required String currentPin,
    required String newPin,
  }) async {
    if (!await _store.verifyPin(currentPin)) return false;
    await _store.setPin(newPin);
    _hasPin = true;
    _sessionUnlocked = true;
    notifyListeners();
    return true;
  }

  Future<bool> clearPin(String currentPin) async {
    if (!await _store.verifyPin(currentPin)) return false;
    await _store.clearPin();
    _hasPin = false;
    _sessionUnlocked = false;
    _lockOnResume = false;
    await _store.saveLockOnResume(false);
    notifyListeners();
    return true;
  }

  Future<void> setLockOnResume(bool value) async {
    _lockOnResume = value;
    await _store.saveLockOnResume(value);
    notifyListeners();
  }

  Future<void> setHideSourceAdult(bool value) async {
    _hideSourceAdult = value;
    await _store.saveHideSourceAdult(value);
    notifyListeners();
  }

  Future<void> setHiddenLiveCategoryIds(Set<String> ids) async {
    _hiddenCategoryIds = Set<String>.from(ids);
    _hiddenIdToName.removeWhere((id, _) => !_hiddenCategoryIds.contains(id));
    await _store.saveHiddenLiveCategoryIds(ids.toList()..sort());
    await _store.saveHiddenLiveCategoryNames(_hiddenIdToName);
    notifyListeners();
  }

  Future<void> toggleHiddenLiveCategory(IptvCategory category) async {
    final next = Set<String>.from(_hiddenCategoryIds);
    if (next.contains(category.id)) {
      next.remove(category.id);
      _hiddenIdToName.remove(category.id);
    } else {
      next.add(category.id);
      final name = category.name.trim();
      if (name.isNotEmpty) _hiddenIdToName[category.id] = name;
    }
    await setHiddenLiveCategoryIds(next);
  }

  Future<void> setHiddenSourceIds(Set<String> ids) async {
    _hiddenSourceIds = {
      for (final id in ids)
        if (id.trim().isNotEmpty) id.trim(),
    };
    await _store.saveHiddenSourceIds(_hiddenSourceIds.toList()..sort());
    notifyListeners();
  }

  Future<void> toggleHiddenSourceId(String sourceId) async {
    final id = sourceId.trim();
    if (id.isEmpty) return;
    final next = Set<String>.from(_hiddenSourceIds);
    if (next.contains(id)) {
      next.remove(id);
    } else {
      next.add(id);
    }
    await setHiddenSourceIds(next);
  }
}
