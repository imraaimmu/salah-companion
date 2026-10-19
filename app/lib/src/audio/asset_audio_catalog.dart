/// Loads the bundled audio catalog (surah:ayah -> asset path + duration).
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:salah_core/salah_core.dart';

class AssetAudioCatalog implements AudioCatalog {
  /// The placeholder tones from `scripts/make_placeholder_audio.py`. The
  /// qari's recordings (#18) will ship with their own catalog.
  static const placeholderCatalog = 'assets/audio/placeholder/catalog.json';

  final MapAudioCatalog _inner;

  AssetAudioCatalog._(this._inner);

  static Future<AssetAudioCatalog> load({
    AssetBundle? bundle,
    String path = placeholderCatalog,
  }) async {
    final raw = await (bundle ?? rootBundle).loadString(path);
    return AssetAudioCatalog.parse(raw);
  }

  /// Parses catalog JSON; throws [FormatException] if it is malformed.
  factory AssetAudioCatalog.parse(String raw) {
    final json = jsonDecode(raw);
    if (json is! Map<String, Object?>) {
      throw const FormatException('audio catalog must be a JSON object');
    }
    return AssetAudioCatalog._(MapAudioCatalog.fromJson(json));
  }

  /// True while the app bundles placeholder tones instead of recitation.
  bool get placeholder => _inner.placeholder;

  int get length => _inner.length;

  @override
  CatalogEntry? entry(int surah, int ayah) => _inner.entry(surah, ayah);
}
