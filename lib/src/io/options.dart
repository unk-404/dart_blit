/// Standardized open options for v0.2.0.
library;

enum FileMode { read, write, readWrite }

enum Durability { none, data, full }

enum PerformanceProfile { auto, throughput, latency, memory }

final class FileOptions {
  const FileOptions({
    this.mode = FileMode.read,
    this.create = true,
    this.truncate = false,
    this.exclusive = false,
    this.direct = false,
    this.durability = Durability.none,
    this.profile = PerformanceProfile.auto,
    this.readAhead = 0,
  });

  final FileMode mode;
  final bool create;
  final bool truncate;
  final bool exclusive;
  final bool direct;
  final Durability durability;
  final PerformanceProfile profile;
  final int readAhead;

  FileOptions copyWith({
    FileMode? mode,
    bool? create,
    bool? truncate,
    bool? exclusive,
    bool? direct,
    Durability? durability,
    PerformanceProfile? profile,
    int? readAhead,
  }) => FileOptions(
    mode: mode ?? this.mode,
    create: create ?? this.create,
    truncate: truncate ?? this.truncate,
    exclusive: exclusive ?? this.exclusive,
    direct: direct ?? this.direct,
    durability: durability ?? this.durability,
    profile: profile ?? this.profile,
    readAhead: readAhead ?? this.readAhead,
  );

  bool get readOnly => mode == FileMode.read;
  bool get writable => mode != FileMode.read;
}
