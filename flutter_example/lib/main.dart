import 'package:blit/bytes.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

/// Minimal demo app for `package:bytes`.
///
/// It only uses the web-safe core library (`package:blit/bytes.dart`), so the
/// same code runs on Flutter mobile/desktop and in the browser.  Native file
/// I/O examples live in `example/bytes_example.dart`.
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'bytes example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: const BytesDemoPage(),
    );
  }
}

class BytesDemoPage extends StatefulWidget {
  const BytesDemoPage({super.key});

  @override
  State<BytesDemoPage> createState() => _BytesDemoPageState();
}

class _BytesDemoPageState extends State<BytesDemoPage> {
  /// Encoded payload: u32 magic followed by a full-width u64.
  final Bytes _payload = _buildPayload();

  /// O(1) zero-copy view over the first four bytes of the u64 field.
  late final Bytes _slice = _payload.slice(4, 8);

  int _counter = 0;

  static Bytes _buildPayload() {
    final mut = BytesMut(12)
      ..putUint32(0xDEADBEEF)
      ..putUint64(Uint64.parse('18446744073709551615'));
    return mut.freeze();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('bytes + Uint64')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('counter', style: textTheme.titleMedium),
              Text('$_counter', style: textTheme.displaySmall),
              const SizedBox(height: 24),
              _row('payload', '${_payload.length} bytes'),
              _row('u32 @0', '0x${_payload.getUint32(0).toRadixString(16)}'),
              _row('u64 @4', _payload.getUint64(4).toString()),
              _row(
                'slice(4, 8)',
                '${_slice.length} bytes, first = '
                    '0x${_slice[0].toRadixString(16)}',
              ),
              const SizedBox(height: 24),
              const Text(
                'Bytes.slice() is O(1) and shares the backing buffer:\n'
                'nothing is copied here.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _counter++),
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 12),
          SelectableText(value),
        ],
      ),
    );
  }
}
