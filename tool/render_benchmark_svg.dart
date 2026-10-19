// Renders benchmark_test JSONL as a small, pastel SVG table for the README.
//
// Usage:
//   dart run tool/render_benchmark_svg.dart --out assets/benchmarks.svg \
//     bench-core.jsonl bench-random.jsonl bench-iocp.jsonl
//
// Only `{...}` lines are parsed; benchmark_test's progress output is ignored.
// Missing rows are skipped, so the chart still renders if a platform-specific
// benchmark (for example IOCP on Linux) is absent.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

final class _Entry {
  final String name;
  final double value;
  final double rme;
  final String compiler;

  _Entry(this.name, this.value, this.rme, this.compiler);
}

final class _Row {
  final String label;
  final String note;
  final String result;
  final double bar;
  final String color;
  final String rmeLabel;

  _Row(this.label, this.note, this.result, this.bar, this.color, this.rmeLabel);
}

final class _Glyph {
  final int advance;
  final String path;

  _Glyph(this.advance, this.path);
}

/// Text rendered as outlines, so GitHub's SVG sanitizer cannot drop a custom
/// font. The source font is Rounded Mplus 1c (SIL OFL 1.1); see assets/fonts/.
final class _SvgFont {
  final int unitsPerEm;
  final Map<String, _Glyph> glyphs;

  _SvgFont(this.unitsPerEm, this.glyphs);

  static _SvgFont load(String path) {
    final json = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    final rawGlyphs = json['glyphs'] as Map<String, dynamic>;
    return _SvgFont(
      json['unitsPerEm'] as int,
      {
        for (final entry in rawGlyphs.entries)
          entry.key: _Glyph(
            (entry.value as Map<String, dynamic>)['advance'] as int,
            (entry.value)['path'] as String,
          ),
      },
    );
  }

  double width(String text, double size) {
    var units = 0;
    for (final rune in text.runes) {
      units += glyphs[String.fromCharCode(rune)]?.advance ?? 0;
    }
    return units * size / unitsPerEm;
  }

  String text(
    String value,
    double x,
    double y,
    double size,
    String fill, {
    String anchor = 'start',
  }) {
    final scale = size / unitsPerEm;
    final total = width(value, size);
    var cursor = switch (anchor) {
      'middle' => x - total / 2,
      'end' => x - total,
      _ => x,
    };
    final out = StringBuffer();
    for (final rune in value.runes) {
      final ch = String.fromCharCode(rune);
      final glyph = glyphs[ch];
      if (glyph == null) {
        cursor += size * 0.5;
        continue;
      }
      if (glyph.path.isNotEmpty) {
        out.writeln(
          '<path d="${glyph.path}" '
          'transform="translate(${cursor.toStringAsFixed(2)} $y) '
          'scale(${scale.toStringAsFixed(5)} ${(-scale).toStringAsFixed(5)})" '
          'fill="$fill"/>',
        );
      }
      cursor += glyph.advance * scale;
    }
    return out.toString();
  }
}

final _font = _SvgFont.load('assets/fonts/mplus_rounded1c_glyphs.json');

void main(List<String> args) {
  var out = 'assets/benchmarks.svg';
  String? commitArg;
  final files = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--out' && i + 1 < args.length) {
      out = args[++i];
    } else if (args[i] == '--commit' && i + 1 < args.length) {
      commitArg = args[++i];
    } else {
      files.add(args[i]);
    }
  }
  if (files.isEmpty) {
    stderr.writeln('usage: render_benchmark_svg.dart --out FILE JSONL...');
    exit(2);
  }

  final entries = <String, _Entry>{};
  for (final file in files) {
    final f = File(file);
    if (!f.existsSync()) continue;
    for (final line in f.readAsLinesSync()) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('{')) continue;
      try {
        final json = jsonDecode(trimmed) as Map<String, dynamic>;
        final name = json['name'] as String;
        final throughput = json['throughput'] as Map<String, dynamic>;
        final stats = json['statistics'] as Map<String, dynamic>?;
        final entry = _Entry(
          name,
          (throughput['value'] as num).toDouble(),
          (stats?['relativeMarginOfError'] as num?)?.toDouble() ?? 0,
          (json['compiler'] as String?) ?? 'jit',
        );
        // Prefer JIT when the same file contains both JIT and AOT records.
        final old = entries[name];
        if (old == null || (old.compiler != 'jit' && entry.compiler == 'jit')) {
          entries[name] = entry;
        }
      } catch (_) {
        // Ignore malformed/non-JSONL lines.
      }
    }
  }
  if (entries.isEmpty) {
    stderr.writeln('no benchmark records found in ${files.join(', ')}');
    exit(2);
  }

  final rows = _rows(entries);
  final commit = _shortCommit(commitArg);
  final svg = _render(rows, entries.length, commit);
  final output = File(out);
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(svg);
  stdout.writeln(out);
}

List<_Row> _rows(Map<String, _Entry> e) {
  final rows = <_Row>[];
  final colors = <String>[
    '#FFB7C5',
    '#A8E6CF',
    '#BDE0FE',
    '#FFD6A5',
    '#CDB4DB',
    '#FFC8DD',
    '#B9FBC0',
  ];

  _Entry? find(String name) {
    final direct = e[name];
    if (direct != null) return direct;
    // package:test groups prefix the name, e.g. "pool 4 pool.read.random4K.w4".
    for (final entry in e.entries) {
      if (entry.key.endsWith(name)) return entry.value;
    }
    return null;
  }

  void add(
    String name,
    String label,
    String note,
    String Function(_Entry) result,
    double Function(_Entry) bar,
  ) {
    final entry = find(name);
    if (entry == null) return;
    rows.add(_Row(
      label,
      note,
      result(entry),
      bar(entry),
      colors[rows.length % colors.length],
      '±${entry.rme.toStringAsFixed(2)}%',
    ));
  }

  add(
    'file.read.8MiB',
    'Sequential read',
    '8 MiB blocks · 1 GiB file',
    (x) => '${(x.value * 8 / 1024).toStringAsFixed(2)} GiB/s',
    (x) => x.value * 8 / 1024,
  );
  add(
    'file.write.8MiB',
    'Sequential write',
    '8 MiB blocks · 1 GiB file',
    (x) => '${(x.value * 8 / 1024).toStringAsFixed(2)} GiB/s',
    (x) => x.value * 8 / 1024,
  );
  add(
    'file.read.random4K',
    'Random pread',
    '4 KiB · 1 GiB file',
    (x) => '${_fmt(x.value)} IOPS',
    (x) => x.value,
  );
  add(
    'file.write.random4K',
    'Random pwrite',
    '4 KiB · 1 GiB file · buffered',
    (x) => '${_fmt(x.value)} IOPS',
    (x) => x.value,
  );
  add(
    'pool.read.random4K.w4',
    'Pool read · 4 workers',
    '4 KiB · batch 32',
    (x) => '${_fmt(x.value * 4 * 32)} IOPS',
    (x) => x.value * 4 * 32,
  );
  add(
    'pool.read.random4K.w8',
    'Pool read · 8 workers',
    '4 KiB · batch 32',
    (x) => '${_fmt(x.value * 8 * 32)} IOPS',
    (x) => x.value * 8 * 32,
  );
  add(
    'pool.read.random4K.w16',
    'Pool read · 16 workers',
    '4 KiB · batch 32',
    (x) => '${_fmt(x.value * 16 * 32)} IOPS',
    (x) => x.value * 16 * 32,
  );
  add(
    'pool.read.sequential4K.w4',
    'Pool sequential',
    '4 KiB · 4 workers · coalesced',
    (x) => '${_fmt(x.value * 32)} IOPS',
    (x) => x.value * 32,
  );

  final randomSize = RegExp(r'^(?:random)?(\d+)g\.');
  String? randomName;
  var randomGiB = 0;
  for (final name in e.keys) {
    final match = randomSize.firstMatch(name);
    if (match != null) {
      randomName = name;
      randomGiB = int.parse(match.group(1)!);
      break;
    }
  }
  if (randomName != null) {
    add(
      randomName,
      'Random pread',
      '4 KiB · $randomGiB GiB file',
      (x) => '${_fmt(x.value)} IOPS',
      (x) => x.value,
    );
    final writeName = randomName.replaceFirst('pread.read', 'pwrite.write');
    add(
      writeName,
      'Random pwrite',
      '4 KiB · $randomGiB GiB file · buffered',
      (x) => '${_fmt(x.value)} IOPS',
      (x) => x.value,
    );
  }

  add(
    'iocp.read.random4K.qd32',
    'IOCP read · QD32',
    '4 KiB · single worker',
    (x) => '${_fmt(x.value * 32)} IOPS',
    (x) => x.value * 32,
  );
  add(
    'iocp.write.random4K.qd32',
    'IOCP write · QD32',
    '4 KiB · single worker · buffered',
    (x) => '${_fmt(x.value * 32)} IOPS',
    (x) => x.value * 32,
  );

  return rows.take(12).toList(growable: false);
}

String _fmt(double value) {
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(2)}M';
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
  return value.toStringAsFixed(0);
}

String _shortCommit(String? explicit) {
  var value = explicit ?? Platform.environment['GITHUB_SHA'];
  if (value == null || value.isEmpty) {
    try {
      final result = Process.runSync('git', ['rev-parse', '--short', 'HEAD']);
      if (result.exitCode == 0) value = (result.stdout as String).trim();
    } catch (_) {
      // Not in a git checkout (for example a pub archive): keep it explicit.
    }
  }
  if (value == null || value.isEmpty) return 'local';
  return value.length > 7 ? value.substring(0, 7) : value;
}

String _render(List<_Row> rows, int totalRecords, String commit) {
  const width = 920;
  final height = 150 + rows.length * 48 + 44;
  final maxBar = rows.fold<double>(1, (m, r) => math.max(m, r.bar));

  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
        '<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="$height" '
        'viewBox="0 0 $width $height" role="img" '
        'aria-label="blit benchmark results at commit $commit">')
    ..writeln('<desc>Benchmark results at commit $commit</desc>')
    ..writeln('<defs>')
    ..writeln(
        '<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">'
        '<stop offset="0" stop-color="#FFF8F0"/>'
        '<stop offset="0.55" stop-color="#FFF0F6"/>'
        '<stop offset="1" stop-color="#EEF7FF"/>'
        '</linearGradient>')
    ..writeln(
        '<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">'
        '<feDropShadow dx="0" dy="2" stdDeviation="3" flood-color="#C084A0" '
        'flood-opacity="0.18"/></filter>')
    ..writeln('</defs>')
    ..writeln('<rect width="$width" height="$height" rx="24" fill="url(#bg)"/>');

  // Cute little stars and dots.
  const stars = <String>[
    'M 830 34 l 4 8 9 1 -7 6 2 9 -8 -5 -8 5 2 -9 -7 -6 9 -1 z',
    'M 872 62 l 3 6 7 1 -5 5 1 7 -6 -4 -6 4 1 -7 -5 -5 7 -1 z',
  ];
  for (final star in stars) {
    b.writeln('<path d="$star" fill="#FFD166" opacity="0.9"/>');
  }
  for (var i = 0; i < 7; i++) {
    b.writeln(
        '<circle cx="${70 + i * 118}" cy="${126 + (i.isEven ? 0 : 8)}" '
        'r="${i.isEven ? 3 : 2}" fill="#F4A7B9" opacity="0.55"/>');
  }

  b
    ..write(_font.text('blit benchmarks', 36, 54, 28, '#4A3542'))
    ..write(_font.text(
        'Windows · Dart 3.13.5 · benchmark_test · commit $commit',
        38,
        80,
        13,
        '#8A7080'))
    ..writeln(
        '<text x="884" y="54" text-anchor="end" '
        'font-family="\'Segoe UI Emoji\', \'Apple Color Emoji\', '
        '\'Noto Color Emoji\', sans-serif" font-size="18" '
        'fill="#B07C96">(◕‿◕)♡</text>');

  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    final y = 108 + i * 48;
    // Log scale: GiB/s and IOPS rows are not directly comparable, but a bar
    // should still show relative magnitude instead of collapsing to 4 px.
    final barWidth = math.max(
      4.0,
      300 * math.log(1 + row.bar) / math.log(1 + maxBar),
    );
    b
      ..writeln(
          '<rect x="22" y="$y" width="876" height="38" rx="12" '
          'fill="#FFFFFF" opacity="0.78" filter="url(#shadow)"/>')
      ..writeln(
          '<circle cx="46" cy="${y + 19}" r="9" fill="${row.color}" '
          'opacity="0.95"/>')
      ..write(_font.text(
          '${i + 1}', 46, y + 23, 11, '#6B4A5B', anchor: 'middle'))
      ..write(_font.text(row.label, 68, y + 17, 14, '#4A3542'))
      ..write(_font.text(row.note, 68, y + 31, 10.5, '#9A7F8D'))
      ..writeln(
          '<rect x="300" y="${y + 14}" width="300" height="10" rx="5" '
          'fill="#F3E5EC"/>')
      ..writeln(
          '<rect x="300" y="${y + 14}" width="${barWidth.toStringAsFixed(1)}" '
          'height="10" rx="5" fill="${row.color}"/>')
      ..write(_font.text(row.result, 616, y + 23, 13.5, '#4A3542'))
      ..write(_font.text(
          row.rmeLabel, 884, y + 23, 10, '#A88A98', anchor: 'end'));
  }

  b
    ..write(_font.text(
        'Generated from $totalRecords benchmark_test JSONL records · '
        'ops/sec scaled to IOPS/GiB/s · pwrite is buffered',
        36,
        height - 20,
        10.5,
        '#A88A98'))
    ..writeln('</svg>');
  return b.toString();
}
