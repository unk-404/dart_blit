// End-to-end IndexedDB backend tests.
//
// Run: dart test -p chrome test/web/idb_test.dart
@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:blit/src/io/web/web.dart';
import 'package:test/test.dart';

final _runId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
var _pathCounter = 0;
final _dbName = 'blit-idb-test-$_runId';

String _newPath(String label) => 'idb-$_runId/$label-${_pathCounter++}.bin';

Uint8List _pattern(int n, {int seed = 0}) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) (seed + i * 17) & 0xFF]);

void main() {
  tearDownAll(() async {
    await shutdownIdbBackend();
  });

  test('write/read/append/truncate/sparse across chunks', () async {
    final path = _newPath('basic');
    final file = await openIdbBytesFile(
      path,
      chunkSize: 256,
      databaseName: _dbName,
    );
    addTearDown(() async {
      if (!file.isClosed) await file.close();
      await deleteIdbFile(path, databaseName: _dbName);
    });

    final head = _pattern(600, seed: 1);
    expect(await file.writeAt(0, head), 600);
    expect(await file.length, 600);

    final back = Uint8List(600);
    expect(await file.readAt(0, back), 600);
    expect(back, head);

    final tail = _pattern(100, seed: 7);
    expect(await file.append(tail), 100);
    final readTail = Uint8List(100);
    expect(await file.readAt(600, readTail), 100);
    expect(readTail, tail);

    await file.truncate(300);
    expect(await file.length, 300);
    final shrunk = Uint8List(400);
    expect(await file.readAt(250, shrunk), 50);
    expect(shrunk.sublist(0, 50), head.sublist(250, 300));
    expect(shrunk.sublist(50), everyElement(0));

    await file.truncate(2000);
    final sparse = Uint8List(200);
    expect(await file.readAt(1000, sparse), 200);
    expect(sparse, everyElement(0));
  });

  test('two logical files share one store without aliasing', () async {
    final a = _newPath('a');
    final b = _newPath('b');
    final fa = await openIdbBytesFile(a, databaseName: _dbName);
    final fb = await openIdbBytesFile(b, databaseName: _dbName);
    addTearDown(() async {
      if (!fa.isClosed) await fa.close();
      if (!fb.isClosed) await fb.close();
      await deleteIdbFile(a, databaseName: _dbName);
      await deleteIdbFile(b, databaseName: _dbName);
    });

    final da = _pattern(80, seed: 11);
    final db = _pattern(80, seed: 22);
    await fa.writeAt(0, da);
    await fb.writeAt(0, db);
    final ra = Uint8List(80);
    final rb = Uint8List(80);
    await fa.readAt(0, ra);
    await fb.readAt(0, rb);
    expect(ra, da);
    expect(rb, db);
  });

  test('reopen persists length/data; read-only rejects writes', () async {
    final path = _newPath('reopen');
    final data = _pattern(300, seed: 4);
    final writer = await openIdbBytesFile(path, databaseName: _dbName);
    await writer.writeAt(0, data);
    await writer.close();

    final reader = await openIdbBytesFile(
      path,
      create: false,
      readOnly: true,
      databaseName: _dbName,
    );
    addTearDown(() async {
      if (!reader.isClosed) await reader.close();
      await deleteIdbFile(path, databaseName: _dbName);
    });
    expect(await reader.length, 300);
    final back = Uint8List(300);
    expect(await reader.readAt(0, back), 300);
    expect(back, data);
    await expectLater(reader.writeAt(0, data), throwsA(isA<StateError>()));
  });
}
