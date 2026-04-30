// Copyright 2024 AliceChat Authors
// SPDX-License-Identifier: MIT
//
// Music System — Domain Layer
// playback_queue.dart
//
// [PlaybackQueue] is a value type representing the ordered list of
// [ResolvedPlaybackSource] entries that make up the playback queue.
//
// It exposes pure operations (add, remove, reorder, shuffle) and always
// returns a new [PlaybackQueue] instance — it is immutable.
//
// The queue is typically stored inside [PlaybackState.queue]; this class
// exists so that queue operations are testable and serializable
// independently of the full [PlaybackState].
//
// Queue indices are 0-based.  The "currently playing" index is tracked
// separately in [PlaybackState.queueIndex].

import 'dart:math' show Random;

import 'resolved_playback_source.dart';

/// Immutable, ordered playback queue.
class PlaybackQueue {
  const PlaybackQueue._(this._items);

  /// Creates a queue from a list of resolved sources.
  factory PlaybackQueue.fromSources(List<ResolvedPlaybackSource> sources) {
    return PlaybackQueue._(List.unmodifiable(sources));
  }

  /// Empty queue constant.
  static const PlaybackQueue empty = PlaybackQueue._([]);

  final List<ResolvedPlaybackSource> _items;

  // -------------------------------------------------------------------------
  // Accessors
  // -------------------------------------------------------------------------

  /// Number of tracks in the queue.
  int get length => _items.length;

  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;

  /// Returns the track at [index] (0-based).
  /// Throws [RangeError] if [index] is out of bounds.
  ResolvedPlaybackSource operator [](int index) => _items[index];

  /// True if [index] is a valid queue index.
  bool containsIndex(int index) => index >= 0 && index < _items.length;

  // -------------------------------------------------------------------------
  // Iterability
  // -------------------------------------------------------------------------

  /// All items in queue order.
  Iterable<ResolvedPlaybackSource> get items => _items;

  /// Iterator for walking the queue without exposing the internal list.
  Iterator<ResolvedPlaybackSource> get iterator => _items.iterator;

  /// Returns a list snapshot.  The returned list is a copy.
  List<ResolvedPlaybackSource> toList() => List.from(_items);

  // -------------------------------------------------------------------------
  // Mutations — all return new [PlaybackQueue] instances
  // -------------------------------------------------------------------------

  /// Appends [source] to the end of the queue.
  PlaybackQueue enqueue(ResolvedPlaybackSource source) {
    return PlaybackQueue._(List.from(_items)..add(source));
  }

  /// Appends all [sources] to the end of the queue.
  PlaybackQueue enqueueAll(List<ResolvedPlaybackSource> sources) {
    return PlaybackQueue._(List.from(_items)..addAll(sources));
  }

  /// Inserts [source] immediately after the currently-playing [currentIndex].
  /// If [currentIndex] is -1 (nothing playing), behaves like [enqueue].
  /// If [currentIndex] is at the end, behaves like [enqueue].
  PlaybackQueue enqueueNext(ResolvedPlaybackSource source, {int currentIndex = -1}) {
    final insertAt = (currentIndex + 1).clamp(0, _items.length);
    final newItems = List<ResolvedPlaybackSource>.from(_items);
    newItems.insert(insertAt, source);
    return PlaybackQueue._(List.unmodifiable(newItems));
  }

  /// Removes the item at [index].
  /// Throws [RangeError] if [index] is out of bounds.
  PlaybackQueue dequeueAt(int index) {
    if (!_containsIndex(index)) {
      throw RangeError.index(index, _items, 'index');
    }
    final newItems = List<ResolvedPlaybackSource>.from(_items)..removeAt(index);
    return PlaybackQueue._(List.unmodifiable(newItems));
  }

  /// Removes the first occurrence of [source] from the queue (by equality
  /// of [ResolvedPlaybackSource.track.id]).
  PlaybackQueue remove(ResolvedPlaybackSource source) {
    final idx = _items.indexWhere((s) => s.track.id == source.track.id);
    if (idx == -1) return this; // no-op if not found
    return dequeueAt(idx);
  }

  /// Moves the item at [oldIndex] to [newIndex], shifting other items
  /// accordingly.  If [newIndex] > [oldIndex], the item moves "down" in
  /// the list (toward the end).
  ///
  /// Throws [RangeError] if either index is out of bounds.
  PlaybackQueue reorder(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return this;
    if (!_containsIndex(oldIndex) || !_containsIndex(newIndex)) {
      throw RangeError('Invalid indices: old=$oldIndex, new=$newIndex, length=$length');
    }
    final newItems = List<ResolvedPlaybackSource>.from(_items);
    final item = newItems.removeAt(oldIndex);
    newItems.insert(newIndex, item);
    return PlaybackQueue._(List.unmodifiable(newItems));
  }

  /// Returns a new queue with the same items in random order.
  /// [currentIndex] is preserved if it points to a track that still exists
  /// after shuffling; otherwise set to -1.
  PlaybackQueue shuffled({int? currentIndex, Random? random}) {
    final rng = random ?? Random();
    final shuffledItems = List<ResolvedPlaybackSource>.from(_items)..shuffle(rng);
    if (currentIndex != null && currentIndex >= 0 && currentIndex < _items.length) {
      final currentTrackId = _items[currentIndex].track.id;
      shuffledItems.indexWhere((s) => s.track.id == currentTrackId);
    }
    return PlaybackQueue._(List.unmodifiable(shuffledItems));
  }

  /// Returns a new queue with all items removed.
  static PlaybackQueue cleared(PlaybackQueue queue) => empty;

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  bool _containsIndex(int index) => index >= 0 && index < _items.length;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackQueue &&
          _items.length == other._items.length &&
          _items.every((s) => other._items.contains(s));

  @override
  int get hashCode => Object.hashAll(_items.map((s) => s.track.id.hashCode));

  @override
  String toString() => 'PlaybackQueue(length: ${_items.length})';
}
