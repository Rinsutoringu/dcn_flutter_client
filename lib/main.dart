import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'bridge/cpp_bridge.dart';

void main() => runApp(const DcnApp());

// Unified toast: bottom-floating dark bar, Material snackbar style
void showAppToast(BuildContext context, String message,
    {bool error = false, Duration duration = const Duration(milliseconds: 1800)}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              error ? Icons.error_outline : Icons.check_circle_outline,
              size: 18,
              color: error ? const Color(0xFFFF6B6B) : const Color(0xFF4ADE80),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                message,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ],
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xE6111111),
        elevation: 4,
        margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        duration: duration,
        dismissDirection: DismissDirection.horizontal,
      ),
    );
}

class Breakpoints {
  static const double small = 720;
  static const double medium = 1100;
  static const double minAppWidth = 480;
  static const double minAppHeight = 560;
  static const double maxAppContent = 1600;
}

enum LayoutSize { small, medium, large }

LayoutSize layoutSizeFor(double width) {
  if (width < Breakpoints.small) return LayoutSize.small;
  if (width < Breakpoints.medium) return LayoutSize.medium;
  return LayoutSize.large;
}

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
  bool _logExpanded = false;

  // Global course cache: prefetched in background after connect, shared across dialogs
  final ValueNotifier<List<Course>> _allCourses =
      ValueNotifier<List<Course>>(const []);
  final ValueNotifier<bool> _allLoaded = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _prefetching = ValueNotifier<bool>(false);
  final ValueNotifier<String?> _prefetchError = ValueNotifier<String?>(null);
  int _prefetchToken = 0;
  static const int _prefetchPageSize = 200;
  static const Duration _prefetchInterval = Duration(milliseconds: 500);

  // Admin list cache: fetched on login, shared with admin management dialog
  final ValueNotifier<List<String>> _adminList =
      ValueNotifier<List<String>>(const []);
  final ValueNotifier<bool> _adminListLoaded = ValueNotifier<bool>(false);
  final ValueNotifier<String?> _adminListError = ValueNotifier<String?>(null);
  int _adminFetchToken = 0;

  Future<void> _refreshAdminList() async {
    final bridge = _bridge;
    if (bridge == null || !_isAdmin) return;
    final token = ++_adminFetchToken;
    _adminListError.value = null;
    final r = await bridge.listAdmins();
    if (token != _adminFetchToken || !mounted) return;
    if (r.isAdmins) {
      final names = [...r.admins]..sort();
      _adminList.value = List<String>.unmodifiable(names);
      _adminListLoaded.value = true;
      _log('*', 'admin list loaded: ${names.length}');
    } else {
      _adminListError.value = r.message;
      _log('!', 'admin list error: ${r.message}');
    }
  }

  void _resetAdminList() {
    _adminFetchToken++;
    _adminList.value = const [];
    _adminListLoaded.value = false;
    _adminListError.value = null;
  }

  Future<void> _startPrefetch() async {
    final bridge = _bridge;
    if (bridge == null) return;
    final token = ++_prefetchToken;
    _allCourses.value = const [];
    _allLoaded.value = false;
    _prefetchError.value = null;
    _prefetching.value = true;
    _log('*', 'prefetch all courses: start');
    try {
      final acc = <Course>[];
      while (true) {
        if (token != _prefetchToken || !mounted) return;
        final r = await bridge.viewAllPage(acc.length, _prefetchPageSize);
        if (token != _prefetchToken || !mounted) return;
        if (r.isErr) {
          _prefetchError.value = r.message;
          _log('!', 'prefetch error: ${r.message}');
          return;
        }
        acc.addAll(r.courses);
        _allCourses.value = List<Course>.unmodifiable(acc);
        if (r.courses.length < _prefetchPageSize) {
          _allLoaded.value = true;
          _log('*', 'prefetch done: ${acc.length} courses');
          return;
        }
        await Future<void>.delayed(_prefetchInterval);
      }
    } finally {
      if (token == _prefetchToken && mounted) {
        _prefetching.value = false;
      }
    }
  }

  void _cancelPrefetch() {
    _prefetchToken++;
    _prefetching.value = false;
  }

  Future<void> _refreshAll() async {
    _cancelPrefetch();
    await _startPrefetch();
  }

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
    _cancelPrefetch();
    _allCourses.dispose();
    _allLoaded.dispose();
    _prefetching.dispose();
    _prefetchError.dispose();
    _adminList.dispose();
    _adminListLoaded.dispose();
    _adminListError.dispose();
    _bridge?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DCN1003 Course Schedule Client'),
        actions: [
          if (_connected)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Chip(
                avatar: Icon(
                  _isAdmin ? Icons.admin_panel_settings : Icons.person,
                  size: 18,
                ),
                label: Text(_isAdmin ? 'admin: $_user' : 'guest (student)'),
              ),
            ),
        ],
      ),
      body: LayoutBuilder(builder: (ctx, box) {
        final size = layoutSizeFor(box.maxWidth);
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: math.min(box.maxWidth, Breakpoints.minAppWidth),
              maxWidth: math.min(box.maxWidth, Breakpoints.maxAppContent),
            ),
            child: Column(
              children: [
                Expanded(
                  child: _MainPanel(
                    layout: size,
                    bridge: _bridge,
                    connected: _connected,
                    isAdmin: _isAdmin,
                    user: _user,
                    defaultExePath: _exeGuess(),
                    onBridgeStart: _startBridge,
                    allCourses: _allCourses,
                    allLoaded: _allLoaded,
                    prefetching: _prefetching,
                    prefetchError: _prefetchError,
                    onRefreshAll: _refreshAll,
                    onConnected: () {
                      setState(() {
                        _connected = true;
                        _isAdmin = false;
                        _user = '';
                      });
                      _startPrefetch();
                    },
                    onPromoted: (user) {
                      setState(() {
                        _isAdmin = true;
                        _user = user;
                      });
                      _refreshAdminList();
                    },
                    onDemoted: () {
                      _resetAdminList();
                      setState(() {
                        _isAdmin = false;
                        _user = '';
                      });
                    },
                    onDisconnected: () {
                      _cancelPrefetch();
                      _resetAdminList();
                      _allCourses.value = const [];
                      _allLoaded.value = false;
                      _prefetchError.value = null;
                      setState(() {
                        _connected = false;
                        _isAdmin = false;
                        _user = '';
                      });
                    },
                    adminList: _adminList,
                    adminListLoaded: _adminListLoaded,
                    adminListError: _adminListError,
                    onRefreshAdmins: _refreshAdminList,
                  ),
                ),
                _LogPanel(
                  entries: _logs,
                  expanded: _logExpanded,
                  onToggle: () => setState(() => _logExpanded = !_logExpanded),
                ),
              ],
            ),
          ),
        );
      }),
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
  final bool expanded;
  final VoidCallback onToggle;

  const _LogPanel({
    required this.entries,
    required this.expanded,
    required this.onToggle,
  });

  @override
  State<_LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<_LogPanel> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant _LogPanel old) {
    super.didUpdateWidget(old);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients && widget.expanded) {
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
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: widget.onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.terminal, color: scheme.primary, size: 18),
                  const SizedBox(width: 8),
                  Text('Bridge Log',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(width: 8),
                  Text('${entries.length} lines',
                      style: Theme.of(context).textTheme.bodySmall),
                  const Spacer(),
                  Icon(
                    widget.expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_up,
                  ),
                ],
              ),
            ),
          ),
          if (widget.expanded)
            SizedBox(
              height: 220,
              child: Container(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: scheme.outlineVariant)),
                ),
                child: Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(8),
                    itemCount: entries.length,
                    itemExtent: 18,
                    cacheExtent: 500,
                    addAutomaticKeepAlives: false,
                    addRepaintBoundaries: true,
                    itemBuilder: (ctx, i) {
                      final e = entries[i];
                      return Row(
                        children: [
                          SizedBox(
                            width: 16,
                            child: Text(
                              e.direction,
                              style: TextStyle(
                                fontFamily: 'Consolas',
                                fontSize: 12,
                                color: _color(ctx, e.direction),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              e.line,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Consolas',
                                fontSize: 12,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MainPanel extends StatefulWidget {
  final LayoutSize layout;
  final CppBridge? bridge;
  final bool connected;
  final bool isAdmin;
  final String user;
  final String defaultExePath;
  final Future<CppBridge> Function(String exe) onBridgeStart;
  final VoidCallback onConnected;
  final void Function(String user) onPromoted;
  final VoidCallback onDemoted;
  final VoidCallback onDisconnected;
  final ValueListenable<List<Course>> allCourses;
  final ValueListenable<bool> allLoaded;
  final ValueListenable<bool> prefetching;
  final ValueListenable<String?> prefetchError;
  final Future<void> Function() onRefreshAll;
  final ValueListenable<List<String>> adminList;
  final ValueListenable<bool> adminListLoaded;
  final ValueListenable<String?> adminListError;
  final Future<void> Function() onRefreshAdmins;

  const _MainPanel({
    required this.layout,
    required this.bridge,
    required this.connected,
    required this.isAdmin,
    required this.user,
    required this.defaultExePath,
    required this.onBridgeStart,
    required this.onConnected,
    required this.onPromoted,
    required this.onDemoted,
    required this.onDisconnected,
    required this.allCourses,
    required this.allLoaded,
    required this.prefetching,
    required this.prefetchError,
    required this.onRefreshAll,
    required this.adminList,
    required this.adminListLoaded,
    required this.adminListError,
    required this.onRefreshAdmins,
  });

  @override
  State<_MainPanel> createState() => _MainPanelState();
}

class _MainPanelState extends State<_MainPanel> {
  late final _exeCtl = TextEditingController(text: widget.defaultExePath);
  final _hostCtl = TextEditingController(text: '127.0.0.1');
  final _portCtl = TextEditingController(text: '9001');

  String _queryMode = 'code';
  final _queryCtl = TextEditingController();
  List<Course> _courses = [];
  bool _busy = false;

  Future<void> _withBusy(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await fn();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String s, {bool error = false}) =>
      showAppToast(context, s, error: error);

  Future<void> _connect() async {
    await _withBusy(() async {
      try {
        final bridge = await widget.onBridgeStart(_exeCtl.text);
        final port = int.tryParse(_portCtl.text) ?? 9001;
        final c1 = await bridge.connect(_hostCtl.text, port);
        if (!c1.isOk) {
          _toast('Connection failed: ${c1.message}', error: true);
          return;
        }
        widget.onConnected();
        _toast('Connected as student');
      } catch (e) {
        _toast('Error: $e', error: true);
      }
    });
  }

  Future<void> _promoteAdmin() async {
    final result = await showDialog<({String user, String pass})>(
      context: context,
      builder: (ctx) => const _AdminLoginDialog(),
    );
    if (result == null) return;
    await _withBusy(() async {
      final r = await widget.bridge!.login(result.user, result.pass);
      if (!r.isOk) {
        _toast('Login failed: ${r.message}', error: true);
        return;
      }
      widget.onPromoted(result.user);
      _toast('Signed in as admin: ${result.user}');
    });
  }

  Future<void> _demoteToStudent() async {
    await _withBusy(() async {
      final r = await widget.bridge!.logout();
      if (!r.isOk) {
        _toast('Logout failed: ${r.message}', error: true);
        return;
      }
      widget.onDemoted();
      _toast('Signed out admin');
    });
  }

  Future<void> _manageAdmins() async {
    final bridge = widget.bridge;
    if (bridge == null) return;
    final selfChangedPassword = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _AdminManagementDialog(
        bridge: bridge,
        currentUser: widget.user,
        adminList: widget.adminList,
        adminListLoaded: widget.adminListLoaded,
        adminListError: widget.adminListError,
        onRefresh: widget.onRefreshAdmins,
      ),
    );
    if (selfChangedPassword == true && mounted) {
      await _withBusy(() async {
        try {
          await bridge.logout();
        } catch (_) {}
        widget.onDemoted();
      });
      _toast('Password changed; you have been signed out');
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(children: [
            Icon(Icons.info_outline),
            SizedBox(width: 8),
              Text('Info'),
          ]),
          content: const Text('Your password was changed. You have been signed out. Please sign in again with the new password.'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _disconnect() async {
    await _withBusy(() async {
      try {
        if (widget.isAdmin) await widget.bridge?.logout();
        await widget.bridge?.disconnect();
        await widget.bridge?.stop();
      } catch (_) {}
      widget.onDisconnected();
      setState(() => _courses = []);
      _toast('Disconnected');
    });
  }

  Future<void> _query() async {
    if (widget.bridge == null) return;
    await _withBusy(() async {
      final arg = _queryCtl.text.trim();
      if (arg.isEmpty) {
        _toast('Enter a search term', error: true);
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
        _toast('Search failed: ${r.message}', error: true);
        setState(() => _courses = []);
      } else {
        setState(() => _courses = r.courses);
        _toast('${r.courses.length} results');
      }
    });
  }

  Future<void> _viewAll() async {
    if (widget.bridge == null) return;
    await showGeneralDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (ctx, a1, a2) => _AllCoursesDialog(
        coursesListenable: widget.allCourses,
        loadedListenable: widget.allLoaded,
        prefetchingListenable: widget.prefetching,
        errorListenable: widget.prefetchError,
        onRefresh: widget.onRefreshAll,
        layout: widget.layout,
      ),
      transitionBuilder: (ctx, anim, secondary, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _showCourseDialog({Course? edit}) async {
    final code = TextEditingController(text: edit?.code ?? '');
    final title = TextEditingController(text: edit?.title ?? '');
    final section = TextEditingController(text: edit?.section ?? '');
    final instructor = TextEditingController(text: edit?.instructor ?? '');
    final day = TextEditingController(text: edit?.day ?? 'Mon');
    final duration = TextEditingController(text: edit?.duration ?? '90');
    final semester = TextEditingController(text: edit?.semester ?? '');
    final classroom = TextEditingController(text: edit?.classroom ?? '');
    final isEdit = edit != null;

    final result = await showDialog<Course>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEdit ? 'Edit course' : 'New course'),
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
                    enabled: !isEdit,
                    decoration: const InputDecoration(labelText: 'Day')),
                TextField(
                    controller: duration,
                    enabled: !isEdit,
                    decoration:
                        const InputDecoration(labelText: 'Duration (min)')),
                TextField(
                    controller: semester,
                    enabled: !isEdit,
                    decoration: const InputDecoration(labelText: 'Semester')),
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
              child: const Text('Cancel')),
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
                semester: semester.text.trim(),
                classroom: classroom.text.trim(),
              ),
            ),
            child: Text(isEdit ? 'Save' : 'Create'),
          ),
        ],
      ),
    );

    if (result == null) return;
    await _withBusy(() async {
      final r = isEdit
          ? await widget.bridge!.update(result)
          : await widget.bridge!.add(result);
      if (r.isOk) {
        _toast(isEdit ? 'Course updated' : 'Course created');
        await _query();
      } else {
        _toast('${isEdit ? "Update" : "Create"} failed: ${r.message}', error: true);
      }
    });
  }

  Future<void> _delete(Course c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm delete'),
        content: Text('Delete ${c.code} / ${c.section} ?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _withBusy(() async {
      final r = await widget.bridge!.deleteCourse(c.code, c.section);
      if (r.isOk) {
        _toast('Course deleted');
        await _query();
      } else {
        _toast('Delete failed: ${r.message}', error: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isSmall = widget.layout == LayoutSize.small;

    return SingleChildScrollView(
      padding: EdgeInsets.all(isSmall ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SizeTransition(
                sizeFactor: anim,
                axisAlignment: -1,
                child: child,
              ),
            ),
            child: widget.connected
                ? KeyedSubtree(
                    key: const ValueKey('query-card'),
                    child: _buildQueryCard(),
                  )
                : KeyedSubtree(
                    key: const ValueKey('connect-card'),
                    child: _buildConnectCard(),
                  ),
          ),
          const SizedBox(height: 12),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: widget.connected
                ? _buildCourseList()
                : const SizedBox.shrink(),
          ),
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
            Text('Connect to Server', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Connects as student.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
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
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _connect,
              icon: const Icon(Icons.link),
              label: Text(_busy ? 'Connecting...' : 'Connect (as student)'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQueryCard() {
    final isSmall = widget.layout == LayoutSize.small;
    final titleAndButtons = <Widget>[
      Text('Course Search', style: Theme.of(context).textTheme.titleLarge),
      FilledButton.tonalIcon(
        onPressed: _busy ? null : _viewAll,
        icon: const Icon(Icons.list_alt),
        label: const Text('All courses'),
      ),
      ValueListenableBuilder<bool>(
        valueListenable: widget.prefetching,
        builder: (ctx, fetching, _) {
          return ValueListenableBuilder<List<Course>>(
            valueListenable: widget.allCourses,
            builder: (ctx, list, _) {
              final count = list.length;
              return OutlinedButton.icon(
                onPressed: (_busy || fetching) ? null : widget.onRefreshAll,
                icon: fetching
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: Text(fetching ? 'Refreshing…($count)' : 'Refresh courses'),
              );
            },
          );
        },
      ),
      if (widget.isAdmin)
        FilledButton.tonalIcon(
          onPressed: _busy ? null : () => _showCourseDialog(),
          icon: const Icon(Icons.add),
          label: const Text('New'),
        )
      else
        OutlinedButton.icon(
          onPressed: _busy ? null : _promoteAdmin,
          icon: const Icon(Icons.admin_panel_settings),
          label: const Text('Admin login'),
        ),
      if (widget.isAdmin)
        OutlinedButton.icon(
          onPressed: _busy ? null : _manageAdmins,
          icon: const Icon(Icons.manage_accounts),
          label: const Text('Manage admins'),
        ),
      if (widget.isAdmin)
        OutlinedButton.icon(
          onPressed: _busy ? null : _demoteToStudent,
          icon: const Icon(Icons.person),
          label: const Text('Sign out admin'),
        ),
      OutlinedButton.icon(
        onPressed: _busy ? null : _disconnect,
        icon: const Icon(Icons.logout),
          label: const Text('Disconnect'),
      ),
    ];

    return Card(
      child: Padding(
        padding: EdgeInsets.all(isSmall ? 12 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: titleAndButtons,
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                    value: 'code',
                    label: Text('By code'),
                    icon: Icon(Icons.tag)),
                ButtonSegment(
                    value: 'instructor',
                    label: Text('By instructor'),
                    icon: Icon(Icons.school)),
                ButtonSegment(
                    value: 'semester',
                    label: Text('By semester'),
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
                  child: const Text('Search'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCourseList() {
    final scheme = Theme.of(context).colorScheme;
    final empty = Card(
      key: const ValueKey('list-empty'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Column(
            children: [
              Icon(Icons.inbox, size: 48, color: scheme.outline),
              const SizedBox(height: 8),
              Text('No data',
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
    final list = Card(
      key: ValueKey('list-${_courses.length}'),
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
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(
                            value: 'delete', child: Text('Delete')),
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
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SizeTransition(
          sizeFactor: anim,
          axisAlignment: -1,
          child: child,
        ),
      ),
      child: _courses.isEmpty ? empty : list,
    );
  }
}

class _AdminLoginDialog extends StatefulWidget {
  const _AdminLoginDialog();

  @override
  State<_AdminLoginDialog> createState() => _AdminLoginDialogState();
}

class _AdminLoginDialogState extends State<_AdminLoginDialog> {
  final _userCtl = TextEditingController(text: '');
  final _passCtl = TextEditingController(text: '');

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(children: [
        Icon(Icons.admin_panel_settings),
        SizedBox(width: 8),
        Text('Admin Login'),
      ]),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _userCtl,
              decoration: const InputDecoration(
                labelText: 'Username',
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passCtl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                prefixIcon: Icon(Icons.lock),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            (user: _userCtl.text.trim(), pass: _passCtl.text),
          ),
          child: const Text('Login'),
        ),
      ],
    );
  }
}

class _AdminManagementDialog extends StatefulWidget {
  final CppBridge bridge;
  final String currentUser;
  final ValueListenable<List<String>> adminList;
  final ValueListenable<bool> adminListLoaded;
  final ValueListenable<String?> adminListError;
  final Future<void> Function() onRefresh;
  const _AdminManagementDialog({
    required this.bridge,
    required this.currentUser,
    required this.adminList,
    required this.adminListLoaded,
    required this.adminListError,
    required this.onRefresh,
  });

  @override
  State<_AdminManagementDialog> createState() => _AdminManagementDialogState();
}

class _AdminManagementDialogState extends State<_AdminManagementDialog> {
  bool _busy = false;
  bool _selfPasswordChanged = false;

  @override
  void initState() {
    super.initState();
    if (!widget.adminListLoaded.value && widget.adminListError.value == null) {
      widget.onRefresh();
    }
  }

  Future<void> _withBusy(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await fn();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final result = await showDialog<({String user, String pass})>(
      context: context,
      builder: (_) => const _AdminCreateDialog(),
    );
    if (result == null) return;
    if (result.user.isEmpty || result.pass.isEmpty) return;
    await _withBusy(() async {
      final r = await widget.bridge.createAdmin(result.user, result.pass);
      if (!mounted) return;
      if (!r.isOk) {
        _showSnack('Create failed: ${r.message}', error: true);
        return;
      }
      _showSnack('Admin created: ${result.user}');
      await widget.onRefresh();
    });
  }

  Future<void> _edit(String oldName) async {
    final result = await showDialog<({String newUser, String newPass})>(
      context: context,
      builder: (_) => _AdminEditDialog(originalName: oldName),
    );
    if (result == null) return;
    final newUser = result.newUser.trim();
    if (newUser.isEmpty) return;
    await _withBusy(() async {
      final r = await widget.bridge.updateAdmin(oldName, newUser, result.newPass);
      if (!mounted) return;
      if (!r.isOk) {
        _showSnack('Update failed: ${r.message}', error: true);
        return;
      }
      if (oldName == widget.currentUser && result.newPass.isNotEmpty) {
        _selfPasswordChanged = true;
        Navigator.pop(context, true);
        return;
      }
      _showSnack('Admin updated: $oldName -> $newUser');
      await widget.onRefresh();
    });
  }

  Future<void> _delete(String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Delete'),
        content: Text('Delete admin account "$name"? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _withBusy(() async {
      final r = await widget.bridge.deleteAdmin(name);
      if (!mounted) return;
      if (!r.isOk) {
        _showSnack('Delete failed: ${r.message}', error: true);
        return;
      }
      _showSnack('Admin deleted: $name');
      await widget.onRefresh();
    });
  }

  void _showSnack(String msg, {bool error = false}) {
    showAppToast(context, msg, error: error);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(children: [
        const Icon(Icons.manage_accounts),
        const SizedBox(width: 8),
        const Text('Admin Accounts'),
        const Spacer(),
        IconButton(
          tooltip: 'Refresh',
          onPressed: _busy ? null : widget.onRefresh,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: 'Add',
          onPressed: _busy ? null : _create,
          icon: const Icon(Icons.person_add),
        ),
      ]),
      content: SizedBox(
        width: 420,
        height: 360,
        child: ValueListenableBuilder<List<String>>(
          valueListenable: widget.adminList,
          builder: (ctx, admins, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: widget.adminListLoaded,
              builder: (ctx, loaded, _) {
                return ValueListenableBuilder<String?>(
                  valueListenable: widget.adminListError,
                  builder: (ctx, error, _) {
                    if (!loaded && error == null) {
                      return const Center(
                          child: CircularProgressIndicator());
                    }
                    if (error != null) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.error_outline,
                                size: 48, color: scheme.error),
                            const SizedBox(height: 8),
                            Text(error),
                            const SizedBox(height: 8),
                            FilledButton(
                              onPressed: widget.onRefresh,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      );
                    }
                    if (admins.isEmpty) {
                      return const Center(child: Text('(No admins)'));
                    }
                    return ListView.separated(
                      itemCount: admins.length,
                      separatorBuilder: (ctx, i) =>
                          const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final name = admins[i];
                        final isSelf = name == widget.currentUser;
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: isSelf
                                ? scheme.primaryContainer
                                : scheme.surfaceContainerHighest,
                            child: Icon(
                              isSelf
                                  ? Icons.person
                                  : Icons.admin_panel_settings,
                              size: 20,
                            ),
                          ),
                          title: Text(name),
                          subtitle:
                              isSelf ? const Text('(current account)') : null,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Edit',
                                onPressed:
                                    _busy ? null : () => _edit(name),
                                icon: const Icon(Icons.edit),
                              ),
                              IconButton(
                                tooltip:
                                    isSelf ? 'Cannot delete self' : 'Delete',
                                onPressed: (_busy || isSelf)
                                    ? null
                                    : () => _delete(name),
                                icon: const Icon(Icons.delete_outline),
                                color: isSelf ? null : scheme.error,
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () => Navigator.pop(context, _selfPasswordChanged),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _AdminCreateDialog extends StatefulWidget {
  const _AdminCreateDialog();
  @override
  State<_AdminCreateDialog> createState() => _AdminCreateDialogState();
}

class _AdminCreateDialogState extends State<_AdminCreateDialog> {
  final _userCtl = TextEditingController();
  final _passCtl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(children: [
        Icon(Icons.person_add),
        SizedBox(width: 8),
        Text('New Admin'),
      ]),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _userCtl,
              decoration: const InputDecoration(
                labelText: 'Username',
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passCtl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                prefixIcon: Icon(Icons.lock),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            (user: _userCtl.text.trim(), pass: _passCtl.text),
          ),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class _AdminEditDialog extends StatefulWidget {
  final String originalName;
  const _AdminEditDialog({required this.originalName});
  @override
  State<_AdminEditDialog> createState() => _AdminEditDialogState();
}

class _AdminEditDialogState extends State<_AdminEditDialog> {
  late final _userCtl = TextEditingController(text: widget.originalName);
  final _passCtl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(children: [
        const Icon(Icons.edit),
        const SizedBox(width: 8),
        Text('Edit: ${widget.originalName}'),
      ]),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _userCtl,
              decoration: const InputDecoration(
                labelText: 'Username',
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passCtl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New Password (leave blank to keep)',
                prefixIcon: Icon(Icons.lock),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            (newUser: _userCtl.text.trim(), newPass: _passCtl.text),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}


enum CourseSortKey { code, title, instructor, section, day, classroom }

const _kSortKeyLabels = {
  CourseSortKey.code: 'By Code',
  CourseSortKey.title: 'By Title',
  CourseSortKey.instructor: 'By Instructor',
  CourseSortKey.section: 'By Semester/Section',
  CourseSortKey.day: 'By Time',
  CourseSortKey.classroom: 'By Classroom',
};

class _AllCoursesDialog extends StatelessWidget {
  final ValueListenable<List<Course>> coursesListenable;
  final ValueListenable<bool> loadedListenable;
  final ValueListenable<bool> prefetchingListenable;
  final ValueListenable<String?> errorListenable;
  final Future<void> Function() onRefresh;
  final LayoutSize layout;
  const _AllCoursesDialog({
    required this.coursesListenable,
    required this.loadedListenable,
    required this.prefetchingListenable,
    required this.errorListenable,
    required this.onRefresh,
    required this.layout,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context).size;
    final double targetW;
    final double targetH;
    switch (layout) {
      case LayoutSize.small:
        targetW = media.width * 0.96;
        targetH = media.height * 0.92;
        break;
      case LayoutSize.medium:
        targetW = math.min(960.0, media.width * 0.92);
        targetH = math.min(720.0, media.height * 0.9);
        break;
      case LayoutSize.large:
        targetW = math.min(1280.0, media.width * 0.9);
        targetH = math.min(800.0, media.height * 0.9);
        break;
    }
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 360,
          minHeight: 480,
          maxWidth: 1400,
          maxHeight: 960,
        ),
        child: SizedBox(
          width: math.max(360.0, targetW),
          height: math.max(480.0, targetH),
          child: _AllCoursesView(
            coursesListenable: coursesListenable,
            loadedListenable: loadedListenable,
            prefetchingListenable: prefetchingListenable,
            errorListenable: errorListenable,
            onRefresh: onRefresh,
            layout: layout,
            onClose: () => Navigator.of(context, rootNavigator: true).pop(),
          ),
        ),
      ),
    );
  }
}

class _AllCoursesView extends StatefulWidget {
  final ValueListenable<List<Course>> coursesListenable;
  final ValueListenable<bool> loadedListenable;
  final ValueListenable<bool> prefetchingListenable;
  final ValueListenable<String?> errorListenable;
  final Future<void> Function() onRefresh;
  final LayoutSize layout;
  final VoidCallback? onClose;
  const _AllCoursesView({
    required this.coursesListenable,
    required this.loadedListenable,
    required this.prefetchingListenable,
    required this.errorListenable,
    required this.onRefresh,
    required this.layout,
    this.onClose,
  });

  @override
  State<_AllCoursesView> createState() => _AllCoursesViewState();
}

class _AllCoursesViewState extends State<_AllCoursesView> {
  final _instructorCtl = TextEditingController();
  final _semesterCtl = TextEditingController();
  final _codeCtl = TextEditingController();
  final _classroomCtl = TextEditingController();
  final _dayCtl = TextEditingController();

  final Set<String> _selectedKeys = <String>{};
  Course? _focused;

  int _smallTab = 0;

  CourseSortKey _sortKey = CourseSortKey.code;
  bool _sortAsc = true;

  late List<Course> _courses;

  List<String> _suggestInstructor = const [];
  List<String> _suggestCode = const [];
  List<String> _suggestClassroom = const [];
  List<String> _suggestDay = const [];
  List<String> _suggestSemester = const [];

  final ScrollController _listCtl = ScrollController();

  String _key(Course c) => '${c.code}|${c.section}|${c.semester}';

  bool _match(Course c) {
    bool ok(String filter, String value) {
      if (filter.trim().isEmpty) return true;
      return value.toLowerCase().contains(filter.trim().toLowerCase());
    }
    return ok(_instructorCtl.text, c.instructor) &&
        ok(_semesterCtl.text, c.semester) &&
        ok(_codeCtl.text, c.code) &&
        ok(_classroomCtl.text, c.classroom) &&
        ok(_dayCtl.text, c.day);
  }

  int _cmp(Course a, Course b) {
    String pick(Course c) {
      switch (_sortKey) {
        case CourseSortKey.code: return c.code;
        case CourseSortKey.title: return c.title;
        case CourseSortKey.instructor: return c.instructor;
        case CourseSortKey.section: return c.section;
        case CourseSortKey.day: return c.day;
        case CourseSortKey.classroom: return c.classroom;
      }
    }
    final r = pick(a).toLowerCase().compareTo(pick(b).toLowerCase());
    return _sortAsc ? r : -r;
  }

  late List<Course> _filteredCache = const [];
  String _cacheSig = '';

  @override
  void initState() {
    super.initState();
    _courses = List<Course>.from(widget.coursesListenable.value);
    _rebuildSuggestions();
    widget.coursesListenable.addListener(_onCoursesChanged);
  }

  @override
  void dispose() {
    widget.coursesListenable.removeListener(_onCoursesChanged);
    _listCtl.dispose();
    _instructorCtl.dispose();
    _semesterCtl.dispose();
    _codeCtl.dispose();
    _classroomCtl.dispose();
    _dayCtl.dispose();
    super.dispose();
  }

  void _onCoursesChanged() {
    if (!mounted) return;
    setState(() {
      _courses = List<Course>.from(widget.coursesListenable.value);
      _cacheSig = '';
      _rebuildSuggestions();
    });
  }

  void _rebuildSuggestions() {
    List<String> uniq(String Function(Course) pick) {
      final s = <String>{};
      for (final c in _courses) {
        final v = pick(c).trim();
        if (v.isNotEmpty) s.add(v);
      }
      final l = s.toList()..sort();
      return l;
    }
    _suggestInstructor = uniq((c) => c.instructor);
    _suggestCode = uniq((c) => c.code);
    _suggestClassroom = uniq((c) => c.classroom);
    _suggestDay = uniq((c) => c.day);
    _suggestSemester = uniq((c) => c.semester);
  }

  void _onFilterFocus() {}

  List<Course> get _filtered {
    final sig = '${_instructorCtl.text}|${_semesterCtl.text}|${_codeCtl.text}|'
        '${_classroomCtl.text}|${_dayCtl.text}|$_sortKey|$_sortAsc|${_courses.length}';
    if (sig != _cacheSig) {
      final list = _courses.where(_match).toList();
      list.sort(_cmp);
      _filteredCache = list;
      _cacheSig = sig;
    }
    return _filteredCache;
  }

  List<Course> get _selectedCourses => _courses
      .where((c) => _selectedKeys.contains(_key(c)))
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 56, 8),
              child: Row(
                children: [
                  Icon(Icons.list_alt, color: scheme.primary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text('All Courses',
                        style: Theme.of(context).textTheme.titleLarge,
                        overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: ValueListenableBuilder<bool>(
                      valueListenable: widget.loadedListenable,
                      builder: (ctx, loaded, _) {
                        final suffix = loaded ? '' : '+';
                        return Text(
                          '${_filtered.length}/${_courses.length}$suffix · ${_selectedKeys.length} selected',
                          style: Theme.of(context).textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        );
                      },
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SizeTransition(
                        sizeFactor: anim,
                        axis: Axis.horizontal,
                        axisAlignment: -1,
                        child: child,
                      ),
                    ),
                    child: _selectedKeys.isEmpty
                        ? const SizedBox(
                            key: ValueKey('clear-empty'),
                            width: 0,
                            height: 0)
                        : Padding(
                            key: const ValueKey('clear-btn'),
                            padding: const EdgeInsets.only(left: 8),
                            child: TextButton.icon(
                              onPressed: () =>
                                  setState(_selectedKeys.clear),
                              icon: const Icon(Icons.clear_all, size: 18),
                              label: const Text('Clear Selection'),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                              ),
                            ),
                          ),
                  ),
                  const Spacer(),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _buildBody(widget.layout)),
          ],
        ),
        if (widget.onClose != null)
          Positioned(
            top: 8,
            right: 8,
            child: Material(
              color: Colors.transparent,
              child: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: widget.onClose,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBody(LayoutSize size) {
    if (size == LayoutSize.small) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                  value: 0,
                  label: Text('List / Filter'),
                  icon: Icon(Icons.list),
                ),
                ButtonSegment(
                  value: 1,
                  label: Text('Weekly'),
                  icon: Icon(Icons.calendar_view_week),
                ),
              ],
              selected: {_smallTab},
              onSelectionChanged: (s) => setState(() => _smallTab = s.first),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, anim) {
                final slide = Tween<Offset>(
                  begin: const Offset(0.06, 0),
                  end: Offset.zero,
                ).animate(anim);
                return FadeTransition(
                  opacity: anim,
                  child: SlideTransition(position: slide, child: child),
                );
              },
              child: KeyedSubtree(
                key: ValueKey('small-tab-$_smallTab'),
                child: _smallTab == 0
                    ? _buildLeftPane()
                    : _buildCalendarPane(),
              ),
            ),
          ),
        ],
      );
    }

    final leftW = size == LayoutSize.medium ? 340.0 : 400.0;
    return Row(
      children: [
        SizedBox(width: leftW, child: _buildLeftPane()),
        const VerticalDivider(width: 1),
        Expanded(child: _buildCalendarPane()),
      ],
    );
  }

  Widget _buildLeftPane() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (ctx, bc) {
                  const gap = 8.0;
                  final maxW = bc.maxWidth;
                  final cols = maxW < 360
                      ? 1
                      : maxW < 560
                          ? 2
                          : maxW < 820
                              ? 3
                              : 4;
                  final fieldW =
                      ((maxW - gap * (cols - 1)) / cols).floorToDouble();
                  Widget cell(Widget child) =>
                      SizedBox(width: fieldW, child: child);
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      cell(_FilterField(
                        label: 'Instructor',
                        icon: Icons.school,
                        controller: _instructorCtl,
                        suggestions: _suggestInstructor,
                        onChanged: () => setState(() {}),
                        onFocus: _onFilterFocus,
                      )),
                      cell(_FilterField(
                        label: 'Semester',
                        icon: Icons.event,
                        controller: _semesterCtl,
                        suggestions: _suggestSemester,
                        onChanged: () => setState(() {}),
                        onFocus: _onFilterFocus,
                      )),
                      cell(_FilterField(
                        label: 'Code',
                        icon: Icons.tag,
                        controller: _codeCtl,
                        suggestions: _suggestCode,
                        onChanged: () => setState(() {}),
                        onFocus: _onFilterFocus,
                      )),
                      cell(_FilterField(
                        label: 'Classroom',
                        icon: Icons.location_on,
                        controller: _classroomCtl,
                        suggestions: _suggestClassroom,
                        onChanged: () => setState(() {}),
                        onFocus: _onFilterFocus,
                      )),
                      cell(_FilterField(
                        label: 'Time/Day',
                        icon: Icons.calendar_today,
                        controller: _dayCtl,
                        suggestions: _suggestDay,
                        onChanged: () => setState(() {}),
                        onFocus: _onFilterFocus,
                      )),
                      SizedBox(
                        width: fieldW - 48 - gap,
                        child: DropdownButtonFormField<CourseSortKey>(
                          initialValue: _sortKey,
                          isDense: true,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Sort',
                            prefixIcon: Icon(Icons.sort, size: 18),
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final k in CourseSortKey.values)
                              DropdownMenuItem(
                                  value: k,
                                  child: Text(_kSortKeyLabels[k]!)),
                          ],
                          onChanged: (v) =>
                              setState(() => _sortKey = v ?? _sortKey),
                        ),
                      ),
                      SizedBox(
                        width: 48,
                        child: IconButton.outlined(
                          tooltip: _sortAsc ? 'Ascending (click to descend)' : 'Descending (click to ascend)',
                          onPressed: () =>
                              setState(() => _sortAsc = !_sortAsc),
                          icon: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            transitionBuilder: (c, a) =>
                                RotationTransition(turns: a, child: c),
                            child: Icon(
                              _sortAsc
                                  ? Icons.arrow_upward
                                  : Icons.arrow_downward,
                              key: ValueKey(_sortAsc),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _filtered.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.search_off,
                            size: 40,
                            color: Theme.of(context).colorScheme.outline),
                        const SizedBox(height: 8),
                        Text('No matching courses',
                            style: Theme.of(context).textTheme.bodyMedium),
                      ],
                    ),
                  ),
                )
              : Scrollbar(
                  controller: _listCtl,
                  thumbVisibility: true,
                  child: CustomScrollView(
                    controller: _listCtl,
                    cacheExtent: 600,
                    slivers: [
                      SliverFixedExtentList(
                        itemExtent: 72,
                        delegate: SliverChildBuilderDelegate(
                          (ctx, i) => _courseTile(_filtered[i]),
                          childCount: _filtered.length,
                        ),
                      ),
                      SliverToBoxAdapter(child: _buildListFooter()),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildListFooter() {
    return ValueListenableBuilder<String?>(
      valueListenable: widget.errorListenable,
      builder: (ctx, err, _) {
        if (err != null) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline,
                    color: Theme.of(context).colorScheme.error, size: 18),
                const SizedBox(width: 8),
                Flexible(
                  child: Text('Load failed: $err',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => widget.onRefresh(),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: widget.prefetchingListenable,
          builder: (ctx, fetching, _) {
            if (!fetching) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Text('Syncing courses in background...',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _courseTile(Course c) {
    final k = _key(c);
    final selected = _selectedKeys.contains(k);
    final focused = _focused != null && _key(_focused!) == k;
    return Material(
      color: focused
          ? Theme.of(context).colorScheme.secondaryContainer
          : Colors.transparent,
      child: CheckboxListTile(
        value: selected,
        dense: true,
        visualDensity: VisualDensity.compact,
        title: Text('${c.code} · ${c.title}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          'Sec ${c.section} · ${c.instructor}\n${c.day} · ${c.duration}min · ${c.classroom}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: true,
        controlAffinity: ListTileControlAffinity.leading,
        onChanged: (v) {
          setState(() {
            if (v == true) {
              _selectedKeys.add(k);
            } else {
              _selectedKeys.remove(k);
            }
            _focused = c;
          });
        },
      ),
    );
  }

  Widget _buildCalendarPane() {
    final scheme = Theme.of(context).colorScheme;
    final hasSelection = _selectedCourses.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.event_note, color: scheme.primary),
              const SizedBox(width: 8),
              Text('Weekly View',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  hasSelection
                      ? '${_selectedCourses.length} course(s) selected'
                      : 'Select courses on the left to view weekly slots',
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _WeeklyCalendar(
              courses: _selectedCourses,
              focused: _focused,
            ),
          ),
        ],
      ),
    );
  }
}


class _FilterField extends StatefulWidget {
  final String label;
  final IconData icon;
  final TextEditingController controller;
  final List<String> suggestions;
  final VoidCallback onChanged;
  final VoidCallback? onFocus;

  const _FilterField({
    required this.label,
    required this.icon,
    required this.controller,
    required this.suggestions,
    required this.onChanged,
    this.onFocus,
  });

  @override
  State<_FilterField> createState() => _FilterFieldState();
}

class _FilterFieldState extends State<_FilterField> {
  FocusNode? _watched;

  void _bindFocus(FocusNode node) {
    if (identical(node, _watched)) return;
    _watched?.removeListener(_onFocusChange);
    _watched = node;
    node.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (_watched?.hasFocus == true) widget.onFocus?.call();
  }

  @override
  void dispose() {
    _watched?.removeListener(_onFocusChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Autocomplete<String>(
        optionsBuilder: (textEditingValue) {
          final q = textEditingValue.text.trim().toLowerCase();
          if (q.isEmpty) return widget.suggestions;
          return widget.suggestions
              .where((s) => s.toLowerCase().contains(q));
        },
        fieldViewBuilder:
            (context, textCtl, focusNode, onFieldSubmitted) {
          _bindFocus(focusNode);
          if (textCtl.text != widget.controller.text) {
            textCtl.text = widget.controller.text;
            textCtl.selection =
                TextSelection.collapsed(offset: textCtl.text.length);
          }
          return TextField(
            controller: textCtl,
            focusNode: focusNode,
            onTap: widget.onFocus,
            decoration: InputDecoration(
              labelText: widget.label,
              prefixIcon: Icon(widget.icon, size: 18),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: textCtl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      splashRadius: 16,
                      onPressed: () {
                        textCtl.clear();
                        widget.controller.clear();
                        widget.onChanged();
                      },
                    ),
            ),
            onChanged: (v) {
              widget.controller.text = v;
              widget.onChanged();
            },
          );
        },
        onSelected: (v) {
          widget.controller.text = v;
          widget.onChanged();
        },
        optionsViewBuilder: (context, onSelected, options) {
          return Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240, maxWidth: 320),
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: options.length,
                  itemBuilder: (ctx, i) {
                    final opt = options.elementAt(i);
                    return InkWell(
                      onTap: () => onSelected(opt),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Text(opt,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        },
      );
  }
}

class _WeeklyCalendar extends StatelessWidget {
  final List<Course> courses;
  final Course? focused;
  const _WeeklyCalendar({required this.courses, required this.focused});

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  int? _dayIndex(String day) {
    final d = day.trim().toLowerCase();
    const map = {
      'mon': 0, 'monday': 0,
      'tue': 1, 'tuesday': 1,
      'wed': 2, 'wednesday': 2,
      'thu': 3, 'thursday': 3,
      'fri': 4, 'friday': 4,
      'sat': 5, 'saturday': 5,
      'sun': 6, 'sunday': 6,
    };
    return map[d];
  }

  ({int startMin, int durationMin})? _slot(Course c) {
    final raw = c.duration.trim();
    final range = RegExp(r'^(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})$')
        .firstMatch(raw);
    if (range != null) {
      final sh = int.parse(range.group(1)!);
      final sm = int.parse(range.group(2)!);
      final eh = int.parse(range.group(3)!);
      final em = int.parse(range.group(4)!);
      final startMin = sh * 60 + sm;
      var dur = (eh * 60 + em) - startMin;
      if (dur <= 0) dur = 60;
      return (startMin: startMin, durationMin: dur);
    }
    final dur = int.tryParse(raw) ?? 60;
    int startMin = 9 * 60;
    for (final tok in c.day.split(RegExp(r'[\s\-_]+'))) {
      final m = RegExp(r'^(\d{1,2}):?(\d{2})?$').firstMatch(tok);
      if (m != null) {
        final h = int.parse(m.group(1)!);
        final mi = int.tryParse(m.group(2) ?? '0') ?? 0;
        startMin = h * 60 + mi;
        break;
      }
    }
    return (startMin: startMin, durationMin: dur);
  }

  Color _colorFor(Course c, ColorScheme scheme) {
    final hue = (c.code.hashCode & 0x7fffffff) % 360;
    final hsl = HSLColor.fromAHSL(
      1.0,
      hue.toDouble(),
      0.55,
      scheme.brightness == Brightness.dark ? 0.45 : 0.7,
    );
    return hsl.toColor();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const dayStartHour = 8;
    const dayEndHour = 22;
    const totalMin = (dayEndHour - dayStartHour) * 60;

    return LayoutBuilder(builder: (ctx, box) {
      const headerH = 28.0;
      const hourCol = 44.0;
      const minColW = 96.0; // Min column width; scroll horizontally below this

      // Adaptive column width: fill first; fall back to min width + horizontal scroll
      final availW = box.maxWidth - hourCol;
      final fitW = availW / _days.length;
      final colW = fitW >= minColW ? fitW : minColW;
      final needsHScroll = fitW < minColW;
      final gridW = hourCol + colW * _days.length;

      // Vertical px/min - at least 26px/hour so text is not cramped
      const minPxPerHour = 26.0;
      final availH = box.maxHeight - headerH;
      final natural = availH / totalMin;
      final pxPerMin = math.max(natural, minPxPerHour / 60);
      final needsVScroll = pxPerMin > natural + 0.0001;
      final gridH = headerH + pxPerMin * totalMin;


      if (courses.isEmpty) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.event_available,
                    size: 48, color: scheme.outline),
                const SizedBox(height: 8),
                Text('No courses',
                    style: Theme.of(ctx).textTheme.bodyMedium),
                const SizedBox(height: 4),
                Text('Select courses on the left to overlay them here',
                    style: Theme.of(ctx)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.outline)),
              ],
            ),
          ),
        );
      }

      Widget dayHeader(int i) => Container(
            width: colW,
            height: headerH,
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: scheme.outlineVariant)),
            ),
            alignment: Alignment.center,
            child: Text(_days[i],
                style: Theme.of(ctx).textTheme.labelMedium),
          );

      final hourLines = <Widget>[];
      for (int h = dayStartHour; h <= dayEndHour; h++) {
        final y = (h - dayStartHour) * 60 * pxPerMin;
        hourLines.add(Positioned(
          left: 0,
          top: headerH + y - 0.5,
          right: 0,
          child: Container(height: 1, color: scheme.outlineVariant),
        ));
        hourLines.add(Positioned(
          left: 4,
          top: headerH + y - 8,
          child: Text('${h.toString().padLeft(2, '0')}:00',
              style: Theme.of(ctx)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.outline)),
        ));
      }

      final blocks = <Widget>[];
      for (final c in courses) {
        final di = _dayIndex(c.day);
        if (di == null) continue;
        final s = _slot(c);
        if (s == null) continue;
        final top = headerH + (s.startMin - dayStartHour * 60) * pxPerMin;
        final h = s.durationMin * pxPerMin;
        if (top < headerH || h <= 0) continue;
        final isFocused = focused != null &&
            focused!.code == c.code &&
            focused!.section == c.section;
        blocks.add(Positioned(
          left: hourCol + di * colW + 2,
          top: top,
          width: colW - 4,
          height: math.max(48, h),
          child: Material(
            color: _colorFor(c, scheme).withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(6),
            elevation: isFocused ? 4 : 1,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(c.code,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 11)),
                  ),
                  Flexible(
                    child: Text(c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10)),
                  ),
                  Flexible(
                    child: Text(c.classroom,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10)),
                  ),
                ],
              ),
            ),
          ),
        ));
      }

      final grid = SizedBox(
        width: gridW,
        height: gridH,
        child: Stack(
          children: [
            Row(
              children: [
                SizedBox(width: hourCol, height: headerH),
                for (int i = 0; i < _days.length; i++) dayHeader(i),
              ],
            ),
            ...hourLines,
            for (int i = 1; i < _days.length; i++)
              Positioned(
                left: hourCol + i * colW,
                top: headerH,
                bottom: 0,
                child: Container(width: 1, color: scheme.outlineVariant),
              ),
            ...blocks,
          ],
        ),
      );

      // Container + bidirectional scroll fallback, never overflows
      Widget content = grid;
      if (needsVScroll) {
        content = SingleChildScrollView(
          scrollDirection: Axis.vertical,
          child: content,
        );
      }
      if (needsHScroll) {
        content = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: content,
        );
      }

      return DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: content,
        ),
      );
    });
  }
}

