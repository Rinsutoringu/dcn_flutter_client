import 'dart:async';
import 'dart:convert';
import 'dart:io';

class Course {
  final String code, title, section, instructor, day, duration, classroom;
  Course({
    required this.code,
    required this.title,
    required this.section,
    required this.instructor,
    required this.day,
    required this.duration,
    required this.classroom,
  });
}

enum BridgeStatus { ok, err, data }

class BridgeResponse {
  final BridgeStatus status;
  final String message;
  final List<Course> courses;
  BridgeResponse(this.status, this.message, this.courses);
  bool get isOk => status == BridgeStatus.ok;
  bool get isErr => status == BridgeStatus.err;
  bool get isData => status == BridgeStatus.data;
}

typedef LogSink = void Function(String direction, String line);

class CppBridge {
  final String exePath;
  final LogSink? onLog;
  Process? _proc;
  StreamQueue<String>? _lines;
  final _writeLock = Completer<void>()..complete();

  CppBridge(this.exePath, {this.onLog});

  bool get isRunning => _proc != null;

  Future<void> start() async {
    if (_proc != null) return;
    final p = await Process.start(
      exePath,
      ['--bridge'],
      workingDirectory: File(exePath).parent.path,
      runInShell: false,
    );
    _proc = p;
    _lines = StreamQueue(
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (l) => onLog?.call('stderr', l),
    );
    final ready = await _lines!.next().timeout(const Duration(seconds: 5));
    onLog?.call('<', ready);
    if (ready.trim() != 'READY') {
      throw StateError('bridge did not emit READY (got "$ready")');
    }
  }

  Future<void> stop() async {
    final p = _proc;
    if (p == null) return;
    try {
      p.stdin.writeln('QUIT');
      await p.stdin.flush();
    } catch (_) {}
    await p.exitCode.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        p.kill();
        return -1;
      },
    );
    await _lines?.cancel();
    _proc = null;
    _lines = null;
  }

  Future<BridgeResponse> _send(List<String> verb) async {
    final p = _proc;
    final lines = _lines;
    if (p == null || lines == null) {
      return BridgeResponse(BridgeStatus.err, 'bridge not started', const []);
    }
    final line = verb.join('\t');
    onLog?.call('>', line);

    while (!_writeLock.isCompleted) {
      await _writeLock.future;
    }

    p.stdin.writeln(line);
    await p.stdin.flush();
    final resp = await lines.next().timeout(const Duration(seconds: 10));
    onLog?.call('<', resp);
    return _parseResponse(resp);
  }

  BridgeResponse _parseResponse(String line) {
    final parts = line.split('\t');
    if (parts.isEmpty) {
      return BridgeResponse(BridgeStatus.err, 'empty response', const []);
    }
    switch (parts[0]) {
      case 'OK':
        return BridgeResponse(
          BridgeStatus.ok,
          parts.length > 1 ? parts[1] : '',
          const [],
        );
      case 'ERR':
        return BridgeResponse(
          BridgeStatus.err,
          parts.length > 1 ? parts[1] : 'unknown error',
          const [],
        );
      case 'DATA':
        final count = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
        final out = <Course>[];
        for (var i = 0; i < count; i++) {
          final base = 2 + i * 7;
          if (base + 6 >= parts.length) break;
          out.add(
            Course(
              code: parts[base],
              title: parts[base + 1],
              section: parts[base + 2],
              instructor: parts[base + 3],
              day: parts[base + 4],
              duration: parts[base + 5],
              classroom: parts[base + 6],
            ),
          );
        }
        return BridgeResponse(BridgeStatus.data, '$count rows', out);
      default:
        return BridgeResponse(
          BridgeStatus.err,
          'unknown status: ${parts[0]}',
          const [],
        );
    }
  }

  Future<BridgeResponse> connect(String host, int port) =>
      _send(['CONNECT', host, '$port']);
  Future<BridgeResponse> disconnect() => _send(['DISCONNECT']);
  Future<BridgeResponse> login(String u, String p) => _send(['LOGIN', u, p]);
  Future<BridgeResponse> logout() => _send(['LOGOUT']);
  Future<BridgeResponse> queryCode(String c) => _send(['QUERY_CODE', c]);
  Future<BridgeResponse> queryInstructor(String n) =>
      _send(['QUERY_INSTRUCTOR', n]);
  Future<BridgeResponse> querySemester(String s) =>
      _send(['QUERY_SEMESTER', s]);
  Future<BridgeResponse> add(Course c) => _send([
    'ADD',
    c.code,
    c.title,
    c.section,
    c.instructor,
    c.day,
    c.duration,
    c.classroom,
  ]);
  Future<BridgeResponse> update(Course c) => _send([
    'UPDATE',
    c.code,
    c.title,
    c.section,
    c.instructor,
    c.day,
    c.duration,
    c.classroom,
  ]);
  Future<BridgeResponse> deleteCourse(String code, String section) =>
      _send(['DELETE', code, section]);
}

class StreamQueue<T> {
  final StreamSubscription<T> _sub;
  final _buffer = <T>[];
  final _waiters = <Completer<T>>[];
  bool _done = false;

  StreamQueue(Stream<T> stream) : _sub = stream.listen(null) {
    _sub
      ..onData(_onData)
      ..onDone(_onDone);
  }

  void _onData(T t) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(t);
    } else {
      _buffer.add(t);
    }
  }

  void _onDone() {
    _done = true;
    for (final c in _waiters) {
      c.completeError(StateError('stream closed'));
    }
    _waiters.clear();
  }

  Future<T> next() {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    if (_done) return Future.error(StateError('stream closed'));
    final c = Completer<T>();
    _waiters.add(c);
    return c.future;
  }

  Future<void> cancel() => _sub.cancel();
}
