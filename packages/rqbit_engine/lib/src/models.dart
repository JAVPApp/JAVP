/// One file inside a torrent (rqbit `/torrents/{id}` details).
class RqbitFile {
  const RqbitFile({
    required this.index,
    required this.name,
    required this.path,
    required this.length,
    this.included = true,
  });

  final int index;
  final String name;
  final String path;
  final int length;
  final bool included;

  factory RqbitFile.fromJson(int index, Map<String, dynamic> json) {
    final components = (json['components'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .where((s) => s.isNotEmpty)
            .toList() ??
        const <String>[];
    final name = (json['name'] as String?)?.trim() ?? '';
    final path = components.isNotEmpty ? components.join('/') : name;
    return RqbitFile(
      index: index,
      name: name.isNotEmpty ? name.split(RegExp(r'[/\\]')).last : path,
      path: path.isNotEmpty ? path : name,
      length: _asInt(json['length']),
      included: json['included'] != false,
    );
  }
}

/// Torrent details from add or `GET /torrents/{id}`.
class RqbitTorrent {
  const RqbitTorrent({
    required this.id,
    required this.infoHash,
    required this.name,
    required this.outputFolder,
    required this.files,
  });

  final int id;
  final String infoHash;
  final String name;
  final String outputFolder;
  final List<RqbitFile> files;

  bool get hasMetadata => files.isNotEmpty || name.isNotEmpty;

  factory RqbitTorrent.fromDetailsJson(Map<String, dynamic> json) {
    final filesJson = json['files'] as List<dynamic>? ?? const [];
    final files = <RqbitFile>[];
    for (var i = 0; i < filesJson.length; i++) {
      final raw = filesJson[i];
      if (raw is Map<String, dynamic>) {
        files.add(RqbitFile.fromJson(i, raw));
      } else if (raw is Map) {
        files.add(RqbitFile.fromJson(i, Map<String, dynamic>.from(raw)));
      }
    }
    return RqbitTorrent(
      id: _asInt(json['id']),
      infoHash: (json['info_hash'] as String?) ?? '',
      name: (json['name'] as String?)?.trim() ?? '',
      outputFolder: (json['output_folder'] as String?) ?? '',
      files: files,
    );
  }

  factory RqbitTorrent.fromAddJson(Map<String, dynamic> json) {
    final details = json['details'];
    final map = details is Map<String, dynamic>
        ? details
        : details is Map
            ? Map<String, dynamic>.from(details)
            : json;
    final parsed = RqbitTorrent.fromDetailsJson(map);
    final rawId = json['id'] ?? map['id'];
    final folder = (json['output_folder'] as String?) ?? parsed.outputFolder;
    return RqbitTorrent(
      id: rawId == null ? parsed.id : _asInt(rawId),
      infoHash: parsed.infoHash,
      name: parsed.name,
      outputFolder: folder,
      files: parsed.files,
    );
  }
}

/// `GET /torrents/{id}/stats/v1`.
class RqbitStats {
  const RqbitStats({
    required this.state,
    required this.progressBytes,
    required this.totalBytes,
    required this.finished,
    this.error,
    this.fileProgress = const [],
  });

  final String state;
  final int progressBytes;
  final int totalBytes;
  final bool finished;
  final String? error;
  final List<int> fileProgress;

  bool get isError => state == 'error' || (error != null && error!.isNotEmpty);

  /// Metadata can exist while librqbit still reports `initializing`.
  /// `POST .../update_only_files` fails until this is true.
  bool get acceptsOnlyFilesUpdate {
    if (isError) return false;
    final s = state.trim().toLowerCase();
    return s == 'live' || s == 'paused';
  }

  double get progress {
    if (totalBytes <= 0) return finished ? 1 : 0;
    return (progressBytes / totalBytes).clamp(0.0, 1.0);
  }

  factory RqbitStats.fromJson(Map<String, dynamic> json) {
    final files =
        (json['file_progress'] as List<dynamic>?)?.map(_asInt).toList() ??
            const <int>[];
    return RqbitStats(
      state: (json['state'] as String?) ?? '',
      progressBytes: _asInt(json['progress_bytes']),
      totalBytes: _asInt(json['total_bytes']),
      finished: json['finished'] == true,
      error: (json['error'] as String?)?.trim(),
      fileProgress: files,
    );
  }
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
