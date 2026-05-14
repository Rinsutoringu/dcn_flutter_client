import 'dart:io';

import 'package:flutter/material.dart';

import 'bridge/cpp_bridge.dart';

void main() => runApp(const DcnApp());

class DcnApp extends StatelessWidget {
  const DcnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DCN1003 Course Schedule',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6750A4),
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFD0BCFF),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  CppBridge? _bridge;
  final _logs = <_LogEntry>[];
  bool _connected = false;
  bool _isAdmin = false;
  String _user = '';

  String _exeGuess() {
    final candidates = [
      r'..\..\build\programs\Client\dcn_client.exe',
      r'..\build\programs\Client\dcn_client.exe',
      r'build\programs\Client\dcn_client.exe',
      r'D:\Handle\dev\dcn\DCN1003-Group21-2026\build\programs\Client\dcn_client.exe',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return File(c).absolute.path;
    }
    return candidates.last;
  }

  void _log(String dir, String line) {
    setState(() {
      _logs.add(_LogEntry(dir, line, DateTime.now()));
      if (_logs.length > 500) _logs.removeAt(0);
    });
  }

  Future<CppBridge> _startBridge(String exePath) async {
    await _bridge?.stop();
    final b = CppBridge(exePath, onLog: _log);
    try {
      await b.start();
      setState(() => _bridge = b);
      _log('*', 'bridge started: $exePath');
      return b;
    } catch (e) {
      _log('!', 'bridge start failed: $e');
      rethrow;
    }
  }

  @override
  void dispose() {
    _bridge?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DCN1003 课程表客户端'),
        actions: [
          if (_connected)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Chip(
                avatar: Icon(
                  _isAdmin ? Icons.admin_panel_settings : Icons.person,
                  size: 18,
                ),
                label: Text(_isAdmin ? 'admin: $_user' : 'guest'),
              ),
            ),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            flex: 3,
            child: _MainPanel(
              bridge: _bridge,
              connected: _connected,
              isAdmin: _isAdmin,
              onBridgeStart: _startBridge,
              onConnected: (admin, user) => setState(() {
                _connected = true;
                _isAdmin = admin;
                _user = user;
              }),
              onDisconnected: () => setState(() {
                _connected = false;
                _isAdmin = false;
                _user = '';
              }),
              defaultExePath: _exeGuess(),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(flex: 2, child: _LogPanel(entries: _logs)),
        ],
      ),
    );
  }
}

class _LogEntry {
  final String direction;
  final String line;
  final DateTime ts;
  _LogEntry(this.direction, this.line, this.ts);
}

class _LogPanel extends StatefulWidget {
  final List<_LogEntry> entries;
  const _LogPanel({required this.entries});

  @override
  State<_LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<_LogPanel> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant _LogPanel old) {
    super.didUpdateWidget(old);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Color _color(BuildContext ctx, String d) {
    final s = Theme.of(ctx).colorScheme;
    switch (d) {
      case '>':
        return s.primary;
      case '<':
        return s.tertiary;
      case '!':
        return s.error;
      default:
        return s.outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(Icons.terminal,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text('Bridge Log',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Text('${entries.length} lines',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(8),
              itemCount: entries.length,
              itemBuilder: (ctx, i) {
                final e = entries[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: RichText(
                    text: TextSpan(
                      style: const TextStyle(
                          fontFamily: 'Consolas', fontSize: 12),
                      children: [
                        TextSpan(
                          text: '${e.direction} ',
                          style: TextStyle(
                            color: _color(ctx, e.direction),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextSpan(
                          text: e.line,
                          style: TextStyle(
                            color: Theme.of(ctx).colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MainPanel extends StatefulWidget {
  final CppBridge? bridge;
  final bool connected;
  final bool isAdmin;
  final String defaultExePath;
  final Future<CppBridge> Function(String exe) onBridgeStart;
  final void Function(bool admin, String user) onConnected;
  final VoidCallback onDisconnected;

  const _MainPanel({
    required this.bridge,
    required this.connected,
    required this.isAdmin,
    required this.defaultExePath,
    required this.onBridgeStart,
    required this.onConnected,
    required this.onDisconnected,
  });

  @override
  State<_MainPanel> createState() => _MainPanelState();
}

class _MainPanelState extends State<_MainPanel> {
  late final _exeCtl = TextEditingController(text: widget.defaultExePath);
  final _hostCtl = TextEditingController(text: '127.0.0.1');
  final _portCtl = TextEditingController(text: '9001');
  final _userCtl = TextEditingController(text: 'admin');
  final _passCtl = TextEditingController(text: 'admin123');

  String _queryMode = 'code';
  final _queryCtl = TextEditingController();
  List<Course> _courses = [];
  bool _busy = false;
  String _status = '';

  Future<void> _withBusy(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await fn();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setStatus(String s) => setState(() => _status = s);

  Future<void> _connectAndLogin() async {
    await _withBusy(() async {
      try {
        final bridge = await widget.onBridgeStart(_exeCtl.text);
        final port = int.tryParse(_portCtl.text) ?? 9001;
        final c1 = await bridge.connect(_hostCtl.text, port);
        if (!c1.isOk) {
          _setStatus('connect failed: ${c1.message}');
          return;
        }
        final c2 = await bridge.login(_userCtl.text, _passCtl.text);
        if (!c2.isOk) {
          _setStatus('login failed: ${c2.message}');
          return;
        }
        widget.onConnected(true, _userCtl.text);
        _setStatus('logged in');
      } catch (e) {
        _setStatus('error: $e');
      }
    });
  }

  Future<void> _disconnect() async {
    await _withBusy(() async {
      try {
        await widget.bridge?.logout();
        await widget.bridge?.disconnect();
        await widget.bridge?.stop();
      } catch (_) {}
      widget.onDisconnected();
      setState(() {
        _courses = [];
        _status = 'disconnected';
      });
    });
  }

  Future<void> _query() async {
    if (widget.bridge == null) return;
    await _withBusy(() async {
      final arg = _queryCtl.text.trim();
      if (arg.isEmpty) {
        _setStatus('enter a query value');
        return;
      }
      late BridgeResponse r;
      switch (_queryMode) {
        case 'code':
          r = await widget.bridge!.queryCode(arg);
          break;
        case 'instructor':
          r = await widget.bridge!.queryInstructor(arg);
          break;
        case 'semester':
          r = await widget.bridge!.querySemester(arg);
          break;
      }
      if (r.isErr) {
        _setStatus('query error: ${r.message}');
        setState(() => _courses = []);
      } else {
        setState(() => _courses = r.courses);
        _setStatus('${r.courses.length} result(s)');
      }
    });
  }

  Future<void> _showCourseDialog({Course? edit}) async {
    final code = TextEditingController(text: edit?.code ?? '');
    final title = TextEditingController(text: edit?.title ?? '');
    final section = TextEditingController(text: edit?.section ?? '');
    final instructor = TextEditingController(text: edit?.instructor ?? '');
    final day = TextEditingController(text: edit?.day ?? 'Mon');
    final duration = TextEditingController(text: edit?.duration ?? '90');
    final classroom = TextEditingController(text: edit?.classroom ?? '');
    final isEdit = edit != null;

    final result = await showDialog<Course>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEdit ? '编辑课程' : '新增课程'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: code,
                    enabled: !isEdit,
                    decoration: const InputDecoration(labelText: 'Code')),
                TextField(
                    controller: title,
                    decoration: const InputDecoration(labelText: 'Title')),
                TextField(
                    controller: section,
                    enabled: !isEdit,
                    decoration: const InputDecoration(labelText: 'Section')),
                TextField(
                    controller: instructor,
                    decoration:
                        const InputDecoration(labelText: 'Instructor')),
                TextField(
                    controller: day,
                    decoration: const InputDecoration(labelText: 'Day')),
                TextField(
                    controller: duration,
                    decoration:
                        const InputDecoration(labelText: 'Duration (min)')),
                TextField(
                    controller: classroom,
                    decoration:
                        const InputDecoration(labelText: 'Classroom')),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(
              ctx,
              Course(
                code: code.text.trim(),
                title: title.text.trim(),
                section: section.text.trim(),
                instructor: instructor.text.trim(),
                day: day.text.trim(),
                duration: duration.text.trim(),
                classroom: classroom.text.trim(),
              ),
            ),
            child: Text(isEdit ? '保存' : '新增'),
          ),
        ],
      ),
    );

    if (result == null) return;
    await _withBusy(() async {
      final r = isEdit
          ? await widget.bridge!.update(result)
          : await widget.bridge!.add(result);
      _setStatus(
          r.isOk ? (isEdit ? 'updated' : 'added') : 'failed: ${r.message}');
      if (r.isOk) await _query();
    });
  }

  Future<void> _delete(Course c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('删除 ${c.code} / ${c.section} ?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await _withBusy(() async {
      final r = await widget.bridge!.deleteCourse(c.code, c.section);
      _setStatus(r.isOk ? 'deleted' : 'failed: ${r.message}');
      if (r.isOk) await _query();
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.connected) _buildConnectCard() else _buildQueryCard(),
          const SizedBox(height: 12),
          if (widget.connected) _buildCourseList(),
          if (_status.isNotEmpty) ...[
            const SizedBox(height: 12),
            _StatusBar(status: _status, busy: _busy),
          ],
        ],
      ),
    );
  }

  Widget _buildConnectCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('连接配置', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
                controller: _exeCtl,
                decoration: const InputDecoration(
                    labelText: 'dcn_client.exe path',
                    prefixIcon: Icon(Icons.folder))),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                    flex: 3,
                    child: TextField(
                        controller: _hostCtl,
                        decoration:
                            const InputDecoration(labelText: 'Host'))),
                const SizedBox(width: 8),
                Expanded(
                    flex: 1,
                    child: TextField(
                        controller: _portCtl,
                        decoration:
                            const InputDecoration(labelText: 'Port'))),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
                controller: _userCtl,
                decoration: const InputDecoration(
                    labelText: 'Username',
                    prefixIcon: Icon(Icons.person))),
            const SizedBox(height: 8),
            TextField(
                controller: _passCtl,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Password', prefixIcon: Icon(Icons.lock))),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _connectAndLogin,
              icon: const Icon(Icons.login),
              label: Text(_busy ? '连接中...' : '连接并登录'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQueryCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('课程查询',
                    style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                if (widget.isAdmin)
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : () => _showCourseDialog(),
                    icon: const Icon(Icons.add),
                    label: const Text('新增'),
                  ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _disconnect,
                  icon: const Icon(Icons.logout),
                  label: const Text('断开'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                    value: 'code',
                    label: Text('按代码'),
                    icon: Icon(Icons.tag)),
                ButtonSegment(
                    value: 'instructor',
                    label: Text('按教师'),
                    icon: Icon(Icons.school)),
                ButtonSegment(
                    value: 'semester',
                    label: Text('按学期'),
                    icon: Icon(Icons.event)),
              ],
              selected: {_queryMode},
              onSelectionChanged: (s) =>
                  setState(() => _queryMode = s.first),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _queryCtl,
                    decoration: const InputDecoration(
                      labelText: 'Query',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onSubmitted: (_) => _query(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _query,
                  child: const Text('查询'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCourseList() {
    if (_courses.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: Column(
              children: [
                Icon(Icons.inbox,
                    size: 48,
                    color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 8),
                Text('无数据',
                    style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
        ),
      );
    }
    return Card(
      child: Column(
        children: [
          for (final c in _courses)
            ListTile(
              leading: CircleAvatar(
                  child: Text(c.code.isNotEmpty ? c.code[0] : '?')),
              title: Text('${c.code} · ${c.title}'),
              subtitle: Text(
                  'Sec ${c.section} · ${c.instructor} · ${c.day} · ${c.duration}min · ${c.classroom}'),
              trailing: widget.isAdmin
                  ? PopupMenuButton<String>(
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('编辑')),
                        PopupMenuItem(
                            value: 'delete', child: Text('删除')),
                      ],
                      onSelected: (v) {
                        if (v == 'edit') _showCourseDialog(edit: c);
                        if (v == 'delete') _delete(c);
                      },
                    )
                  : null,
            ),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final String status;
  final bool busy;
  const _StatusBar({required this.status, required this.busy});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          if (busy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(Icons.info_outline,
                size: 16,
                color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
              child: Text(status,
                  style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
