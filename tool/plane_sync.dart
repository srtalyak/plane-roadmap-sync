// ROADMAP.md -> Plane, one way. README.md is the manual.
//
// The ROADMAP is the source of truth; one project on a Plane instance mirrors
// it. One top-level `- [ ]` / `- [x]` line under a `## Phase` heading is one work
// item, linked by an invisible key at the end of the line: `<!-- DEMO-12 -->`.
// The tool owns an item's state, its cycle and its description; it sets the
// title, the module and the labels when it creates the item and never touches
// them again. It deletes nothing, ever.
//
//   dart run tool/plane_sync.dart check              # dry run (exit 1 if out of sync)
//   dart run tool/plane_sync.dart apply              # up-to-date default branch: write to Plane, write new keys
//   dart run tool/plane_sync.dart apply --no-create  # where HEAD holds the remote default branch: keyed lines only (the git hook)
//   dart run tool/plane_sync.dart setup              # create missing cycles, modules, labels
//
// The project lives in `plane-sync.json`; the token is `PLANE_API_KEY=...` in
// the main clone's `secrets/plane.env` (gitignored, or the tool refuses to run).
// A worktree reads it there through the common git dir. The tool refuses any
// project but the configured one and only ever writes there. Plane's API allows
// 60 requests a minute: every call is paced.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const roadmapPath = 'ROADMAP.md';
const configFile = 'plane-sync.json';
const keyFile = 'secrets/plane.env';
const cacheFile = 'secrets/plane-sync-cache.json';
const defaultPace = Duration(milliseconds: 1100);
const defaultTimeout = Duration(seconds: 30);
const gateLabel = 'gate';

// ---------------------------------------------------------------------------
// The config (pure).

class Config {
  Config({
    required this.planeUrl,
    required this.workspace,
    required this.projectId,
    required this.identifier,
    required this.repoUrl,
    required this.defaultBranch,
    required this.cycles,
    required this.modules,
    required this.labels,
    required this.phaseModules,
    required this.boxModules,
  });

  final String planeUrl;
  final String workspace;
  final String projectId;

  /// Plane's identifier: the `DEMO` of `<!-- DEMO-12 -->`.
  final String identifier;
  final String repoUrl;

  /// The only branch a creating `apply` runs on; every `apply` needs a HEAD
  /// holding all of it on `origin`.
  final String defaultBranch;
  final List<({String name, String start, String end, String description})> cycles;
  final List<String> modules;
  final Map<String, String> labels;

  /// By phase, for every line of the phase. A phase with no row needs a
  /// [boxModules] row per box.
  final Map<String, String> phaseModules;

  /// By box id; wins over [phaseModules].
  final Map<String, String> boxModules;

  String get projectUrl => '$planeUrl/api/v1/workspaces/$workspace/projects/$projectId';

  static const _keys = {
    'planeUrl', 'workspace', 'projectId', 'identifier', 'repoUrl', 'defaultBranch', //
    'cycles', 'modules', 'labels', 'phaseModules', 'boxModules',
  };

  /// A typo must not quietly mean a default, so every key is known or refused.
  factory Config.parse(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    for (final k in json.keys) {
      if (!_keys.contains(k)) throw FormatException('$configFile: unknown key $k');
    }
    T need<T>(String key) {
      final v = json[key];
      if (v is! T) throw FormatException('$configFile: $key is missing or malformed');
      return v;
    }

    Map<String, String> strings(String key) => (json[key] as Map? ?? const {}).cast<String, String>();
    final config = Config(
      planeUrl: need<String>('planeUrl').replaceFirst(RegExp(r'/+$'), ''),
      workspace: need<String>('workspace'),
      projectId: need<String>('projectId'),
      identifier: need<String>('identifier'),
      repoUrl: need<String>('repoUrl').replaceFirst(RegExp(r'/+$'), ''),
      defaultBranch: json['defaultBranch'] as String? ?? 'main',
      cycles: [
        for (final c in need<List<dynamic>>('cycles').cast<Map<String, dynamic>>())
          (
            name: c['name'] as String,
            start: c['start'] as String,
            end: c['end'] as String,
            description: c['description'] as String? ?? '',
          ),
      ],
      modules: need<List<dynamic>>('modules').cast<String>(),
      labels: strings('labels'),
      phaseModules: strings('phaseModules'),
      boxModules: strings('boxModules'),
    );
    if (!RegExp(r'^[A-Z0-9]+$').hasMatch(config.identifier)) {
      throw FormatException('$configFile: identifier must be Plane\'s, in capitals: ${config.identifier}');
    }
    if (!config.labels.containsKey(gateLabel)) {
      throw FormatException('$configFile: labels must hold "$gateLabel"');
    }
    for (final m in [...config.phaseModules.values, ...config.boxModules.values]) {
      if (!config.modules.contains(m)) {
        throw FormatException('$configFile: $m is not in modules');
      }
    }
    return config;
  }
}

// ---------------------------------------------------------------------------
// The ROADMAP side (pure).

class RoadmapBox {
  RoadmapBox({
    required this.lineIndex,
    required this.checked,
    required this.body,
    required this.phase,
    required this.key,
  });

  /// 0-based index into the file's `\n`-separated lines.
  final int lineIndex;
  final bool checked;

  /// The line after `- [ ] `, with the key comment removed.
  final String body;

  /// `Phase 0`, `Phase 1` ...
  final String phase;

  /// The Plane sequence id, when the line carries a key.
  final int? key;

  /// `**NAME**` at the start of the line without a trailing colon, else null.
  String? get name {
    final m = _namePattern.firstMatch(body);
    return m == null ? null : _cleanName(m.group(1)!);
  }

  /// `P1-05` or `G1`; null on a line with no box id.
  String? get id {
    final n = name;
    if (n == null) return null;
    final m = _idPattern.firstMatch(n);
    return m == null ? null : (m.group(1) ?? m.group(2));
  }

  bool get isGate => name?.startsWith('Gate G') ?? false;

  bool get cancelled => !checked && cancelledPattern.hasMatch(body);

  String get title => deriveTitle(body);
}

final cancelledPattern = RegExp(r'\bSKIPPED\b|\b[Ww]ithdrawn\b|\b[Ss]uperseded\b');

final _namePattern = RegExp(r'^\*\*([^*]+)\*\*');
final _idPattern = RegExp(r'^(?:(P\d-[A-Z0-9]+)|Gate (G\d))\b');
final _boxPattern = RegExp(r'^- \[( |x|X)\] (.*)$');
final _phasePattern = RegExp(r'^## Phase (\d)\b');

String _cleanName(String s) => s.trim().replaceFirst(RegExp(r':$'), '').trimRight();

/// Items live under `## Phase N` only: other sections hold rituals. Lines are
/// split as the writer splits them, so an index means the same line on both
/// sides, in an LF or a CRLF file.
List<RoadmapBox> parseRoadmap(Config config, String text) {
  final keyPattern = RegExp('\\s*<!--\\s*${config.identifier}-(\\d+)\\s*-->\\s*\$');
  final boxes = <RoadmapBox>[];
  String? phase;
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (line.startsWith('## ')) {
      final m = _phasePattern.firstMatch(line);
      phase = m == null ? null : 'Phase ${m.group(1)}';
      continue;
    }
    if (phase == null) continue;
    final m = _boxPattern.firstMatch(line);
    if (m == null) continue;
    var body = m.group(2)!;
    int? key;
    final k = keyPattern.firstMatch(body);
    if (k != null) {
      key = int.parse(k.group(1)!);
      body = body.substring(0, k.start).trimRight();
    }
    boxes.add(RoadmapBox(
      lineIndex: i,
      checked: m.group(1) != ' ',
      body: body,
      phase: phase,
      key: key,
    ));
  }
  return boxes;
}

/// Appends the key to a line, before its `\r` if the file is CRLF.
String lineWithKey(Config config, String line, int key) {
  final cr = line.endsWith('\r');
  final base = cr ? line.substring(0, line.length - 1) : line;
  return '${base.trimRight()} <!-- ${config.identifier}-$key -->${cr ? '\r' : ''}';
}

/// Removes `*( ... )*` annotation blocks (balanced parentheses inside).
String stripAnnotations(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    if (s.startsWith('*(', i)) {
      var depth = 0;
      var j = i + 1;
      for (; j < s.length; j++) {
        if (s[j] == '(') depth++;
        if (s[j] == ')') {
          depth--;
          if (depth == 0) break;
        }
      }
      if (j < s.length && s.startsWith(')*', j)) {
        i = j + 2;
        continue;
      }
    }
    out.write(s[i]);
    i++;
  }
  return out.toString();
}

/// Drops one leading parenthetical: `(session: ...)`, `(3 days)`.
String _dropLeadingParenthetical(String s) {
  final t = s.trimLeft();
  if (!t.startsWith('(')) return s;
  var depth = 0;
  for (var j = 0; j < t.length; j++) {
    if (t[j] == '(') depth++;
    if (t[j] == ')') {
      depth--;
      if (depth == 0) return t.substring(j + 1);
    }
  }
  return s;
}

/// Drops one trailing parenthetical: the estimate, or a `(session: ...)` note.
String _dropTrailingParenthetical(String s) {
  final t = s.trimRight();
  if (!t.endsWith(')')) return s;
  var depth = 0;
  for (var j = t.length - 1; j >= 0; j--) {
    if (t[j] == ')') depth++;
    if (t[j] == '(') {
      depth--;
      if (depth == 0) return t.substring(0, j);
    }
  }
  return s;
}

String _plain(String s) => s
    .replaceAll(RegExp(r'\*\*|`'), '')
    .replaceAll(RegExp(r'(?<![\w)])\*(?=\S)|(?<=\S)\*(?![\w(])'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _cut(String s, int max) {
  if (s.length <= max) return s;
  final at = s.lastIndexOf(' ', max);
  return '${s.substring(0, at < max ~/ 2 ? max : at).trimRight()}...';
}

/// Up to the first clause break outside parentheses.
String _firstClause(String s) {
  var depth = 0;
  for (var i = 0; i < s.length; i++) {
    if (s[i] == '(') depth++;
    if (s[i] == ')') depth--;
    if (depth > 0) continue;
    if (s.startsWith(' - ', i) || s.startsWith('; ', i) || s.startsWith('. ', i) || s.startsWith(': ', i)) {
      return s.substring(0, i).trim();
    }
  }
  return s.trim();
}

/// `P1-01 NAME - gloss`, without the estimate; a line with no bold name is cut
/// at 120 characters on a word boundary.
String deriveTitle(String body) {
  final nameMatch = _namePattern.firstMatch(body);
  if (nameMatch == null) return _cut(_plain(stripAnnotations(body)), 120);
  final name = _cleanName(nameMatch.group(1)!);
  var rest = stripAnnotations(body.substring(nameMatch.end));
  rest = _dropLeadingParenthetical(rest);
  rest = _dropTrailingParenthetical(rest).trim();
  rest = rest.replaceFirst(RegExp(r'^-+\s*'), '');
  final gloss = _cut(_plain(_firstClause(rest)).replaceFirst(RegExp(r'\.$'), ''), 90);
  return gloss.isEmpty ? name : '$name - $gloss';
}

/// Plane's state names. A box is Todo until it is ticked: the board shows what
/// is finished, not what someone is on.
String desiredState(RoadmapBox box) {
  if (box.checked) return 'Done';
  if (box.cancelled) return 'Cancelled';
  return 'Todo';
}

/// The module a new item is filed under. Never changed later.
String? defaultModule(Config config, String? id, String phase) =>
    config.boxModules[id] ?? config.phaseModules[phase];

/// A cycle whose end date has passed refuses new issues (Plane answers
/// `CYCLE_COMPLETED`).
bool cycleIsClosed(String? endDate, DateTime now) {
  if (endDate == null) return false;
  final end = DateTime.tryParse(endDate);
  return end != null && end.isBefore(now);
}

/// The labels a new item is born with: `gate` on a gate line, and its phase as
/// `cyc:` when that cycle is closed, standing in for membership.
List<String> creationLabelNames({
  required bool isGate,
  required String phase,
  required bool cycleClosed,
}) =>
    [
      if (isGate) gateLabel,
      if (cycleClosed) 'cyc:$phase',
    ];

/// The cycle an item belongs in: its phase's cycle while that cycle is open; an
/// **open** item of a closed phase rolls forward into the current cycle; a
/// ticked or cancelled item of a closed phase stays out of every cycle (its
/// `cyc:` label is its history). Null = no cycle.
String? targetCycle({
  required String? phaseCycleId,
  required bool phaseClosed,
  required bool open,
  required String? currentCycleId,
}) {
  if (phaseCycleId == null) return null;
  if (!phaseClosed) return phaseCycleId;
  return open ? currentCycleId : null;
}

/// The cycle running today, else the next one to start, else null.
String? currentCycleOf(List<Map<String, dynamic>> cycles, DateTime now) {
  String? next;
  DateTime? nextStart;
  for (final c in cycles) {
    final start = DateTime.tryParse(c['start_date'] as String? ?? '');
    final end = DateTime.tryParse(c['end_date'] as String? ?? '');
    if (start == null || end == null) continue;
    if (!start.isAfter(now) && !end.isBefore(now)) return c['id'] as String;
    if (start.isAfter(now) && (nextStart == null || start.isBefore(nextStart))) {
      next = c['id'] as String;
      nextStart = start;
    }
  }
  return next;
}

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String descriptionHtml(Config config, RoadmapBox box, String sha) {
  final link = '${config.repoUrl}/blob/$sha/$roadmapPath?plain=1#L${box.lineIndex + 1}';
  return '<p>${_escape(_plain(box.body))}</p>'
      '<p>ROADMAP.md L${box.lineIndex + 1} at ${sha.substring(0, 8)}: '
      '<a href="$link">$link</a></p>';
}

/// The common git dir's parent: where `secrets/` lives, whatever the worktree.
String mainCloneOf(String commonDir) {
  final dir = commonDir.trim().replaceAll(r'\', '/');
  if (!dir.endsWith('/.git')) {
    throw StateError('not a clone with a .git directory: $dir');
  }
  return dir.substring(0, dir.length - '/.git'.length);
}

/// A typo must never fall through to a creating `apply`, so every argument is
/// known or refused.
({String command, bool noCreate}) parseCommand(List<String> args) {
  final command = args.isEmpty ? 'check' : args.first;
  final flags = args.skip(1).toList();
  final known = switch (command) {
    'check' || 'setup' => const <String>{},
    'apply' => const {'--no-create'},
    _ => throw ArgumentError('unknown command: $command'),
  };
  for (final f in flags) {
    if (!known.contains(f)) throw ArgumentError('unknown argument: $f');
  }
  return (command: command, noCreate: flags.contains('--no-create'));
}

// ---------------------------------------------------------------------------
// Plane (I/O).

abstract class PlaneClient {
  int get calls;

  Future<dynamic> send(String method, String path, [Object? body]);

  Future<dynamic> get(String path) => send('GET', path);
  Future<dynamic> post(String path, Object body) => send('POST', path, body);
  Future<dynamic> patch(String path, Object body) => send('PATCH', path, body);

  /// Every page of a paginated list.
  Future<List<Map<String, dynamic>>> all(String path) async {
    final out = <Map<String, dynamic>>[];
    String? cursor;
    while (true) {
      final sep = path.contains('?') ? '&' : '?';
      final page = await get('$path${sep}per_page=100${cursor == null ? '' : '&cursor=$cursor'}');
      if (page is List) {
        out.addAll(page.cast<Map<String, dynamic>>());
        return out;
      }
      final map = page as Map<String, dynamic>;
      out.addAll((map['results'] as List).cast<Map<String, dynamic>>());
      if (map['next_page_results'] != true) return out;
      cursor = map['next_cursor'] as String?;
    }
  }

  void close() {}
}

class PlaneApi extends PlaneClient {
  PlaneApi(
    this._key, {
    required this.base,
    this.pace = defaultPace,
    this.timeout = defaultTimeout,
  }) : _client = HttpClient()..connectionTimeout = timeout;

  final String _key;
  final String base;
  final Duration pace;

  /// Per step of a call: the hook runs in the foreground of a commit.
  final Duration timeout;
  final HttpClient _client;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  int calls = 0;

  @override
  Future<dynamic> send(String method, String path, [Object? body]) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final wait = pace - DateTime.now().difference(_last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      _last = DateTime.now();
      calls++;
      final uri = Uri.parse('$base$path');
      final req = await _client.openUrl(method, uri);
      req.headers.set('X-API-Key', _key);
      req.headers.set('Accept', 'application/json');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close().timeout(timeout);
      final text = await utf8.decodeStream(res).timeout(timeout);
      if (res.statusCode == 429) {
        final retry = int.tryParse(res.headers.value('retry-after') ?? '') ?? 30;
        stderr.writeln('  429: waiting ${retry}s');
        await Future<void>.delayed(Duration(seconds: retry));
        continue;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final detail = text.length > 300 ? text.substring(0, 300) : text;
        throw HttpException('$method $uri -> ${res.statusCode}: $detail');
      }
      return text.isEmpty ? null : jsonDecode(text);
    }
    throw const HttpException('rate limited four times in a row');
  }

  @override
  void close() => _client.close(force: true);
}

Future<String> readKey(File file) async {
  if (!file.existsSync()) {
    throw StateError('$keyFile missing: PLANE_API_KEY=... (a personal API token from Plane)');
  }
  for (final line in await file.readAsLines()) {
    final m = RegExp(r'^\s*PLANE_API_KEY\s*=\s*(\S+)\s*$').firstMatch(line);
    if (m != null) return m.group(1)!;
  }
  throw StateError('$keyFile holds no PLANE_API_KEY');
}

Future<String> _git(List<String> args, [String? dir]) async {
  final r = await Process.run('git', args, workingDirectory: dir);
  if (r.exitCode != 0) throw StateError('git ${args.join(' ')} failed: ${r.stderr}');
  return (r.stdout as String).trim();
}

/// The main clone of the checkout at [dir]: where `secrets/` lives.
Future<String> findMainClone([String? dir]) async =>
    mainCloneOf(await _git(['rev-parse', '--path-format=absolute', '--git-common-dir'], dir));

/// Whether HEAD holds all of `origin/<branch>`. A checkout that does not would
/// write older states back; any git failure, a missing ref too, answers no.
Future<bool> holdsRemoteBranch(String branch, [String? dir]) async {
  final r = await Process.run(
    'git',
    ['merge-base', '--is-ancestor', 'origin/$branch', 'HEAD'],
    workingDirectory: dir,
  );
  return r.exitCode == 0;
}

/// The token sits in the working tree: refuse a repo that could commit it.
Future<void> requireIgnored(String mainClone) async {
  final r = await Process.run('git', ['check-ignore', '-q', keyFile], workingDirectory: mainClone);
  if (r.exitCode != 0) throw StateError('refusing: add secrets/ to .gitignore first');
}

Map<String, String> readCache(File file) {
  if (!file.existsSync()) return {};
  return (jsonDecode(file.readAsStringSync()) as Map).cast<String, String>();
}

void writeCache(File file, Map<String, String> cache) {
  file.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(cache));
}

/// The guard: never remove it. Every command passes here before any write.
Future<void> checkProject(Config config, PlaneClient api) async {
  final project = await api.get('/') as Map<String, dynamic>;
  if (project['identifier'] != config.identifier || project['id'] != config.projectId) {
    throw StateError('refusing: the project is not ${config.identifier} (${config.projectId})');
  }
}

// ---------------------------------------------------------------------------
// The commands.

class PlaneItem {
  PlaneItem({required this.id, required this.sequence, required this.name, required this.stateId});

  final String id;
  final int sequence;
  final String name;
  final String stateId;
  String? cycleId;
}

class Context {
  Context(this.config, this.api, this.now);
  final Config config;
  final PlaneClient api;
  final DateTime now;
  late final Map<String, String> stateId; // name -> id
  late final Map<String, String> stateName; // id -> name
  late final Map<String, String> labelId; // name -> id
  late final Map<String, String> cycleId; // name -> id
  late final Map<String, String> cycleName; // id -> name
  late final Set<String> closedCycles; // end date passed: no new issues
  late final String? currentCycleId; // the cycle running today, else the next
  late final Map<String, String> moduleId; // name -> id
  late final List<PlaneItem> items;

  Future<void> load() async {
    await checkProject(config, api);
    Map<String, String> byName(List<Map<String, dynamic>> xs) =>
        {for (final x in xs) x['name'] as String: x['id'] as String};
    final states = await api.all('/states/');
    stateId = byName(states);
    stateName = {for (final e in stateId.entries) e.value: e.key};
    labelId = byName(await api.all('/labels/'));
    final cycles = await api.all('/cycles/');
    cycleId = byName(cycles);
    cycleName = {for (final e in cycleId.entries) e.value: e.key};
    closedCycles = {
      for (final c in cycles)
        if (cycleIsClosed(c['end_date'] as String?, now)) c['id'] as String,
    };
    currentCycleId = currentCycleOf(cycles, now);
    moduleId = byName(await api.all('/modules/'));
    final raw = await api.all('/issues/');
    items = [
      for (final r in raw)
        PlaneItem(
          id: r['id'] as String,
          sequence: r['sequence_id'] as int,
          name: r['name'] as String,
          stateId: r['state'] as String,
        ),
    ];
    final byItemId = {for (final it in items) it.id: it};
    for (final entry in cycleId.entries) {
      final rows = await api.all('/cycles/${entry.value}/cycle-issues/');
      for (final row in rows) {
        // v1 answers the issues themselves; an older shape wraps them.
        final issue = row.containsKey('sequence_id') ? row : row['issue'];
        final id = issue is Map ? issue['id'] as String? : issue as String?;
        if (id != null) byItemId[id]?.cycleId = entry.value;
      }
    }
  }

  /// Everything a line will ask for exists, or nothing is written.
  void requireSetup(List<RoadmapBox> boxes) {
    final missing = <String>[
      for (final s in const ['Todo', 'Done', 'Cancelled'])
        if (!stateId.containsKey(s)) 'state $s',
      for (final phase in boxes.map((b) => b.phase).toSet())
        if (!cycleId.containsKey(phase)) 'cycle $phase',
      for (final m in boxes.map((b) => defaultModule(config, b.id, b.phase)).nonNulls.toSet())
        if (!moduleId.containsKey(m)) 'module $m',
      if (boxes.any((b) => b.isGate) && !labelId.containsKey(gateLabel)) 'label $gateLabel',
    ];
    if (missing.isNotEmpty) {
      throw StateError('missing in Plane: ${missing.join(', ')}; run setup first');
    }
  }

  Future<String> ensureLabel(String name) async {
    final have = labelId[name];
    if (have != null) return have;
    final created = await api.post('/labels/', {'name': name, 'color': '#6b7280'}) as Map;
    return labelId[name] = created['id'] as String;
  }
}

/// `check` when [apply] is false. Every `apply` needs a HEAD that holds all of
/// the remote default branch ([holdsDefault]): a checkout behind it, the main
/// clone too, must not write older states back. A creating `apply` also runs on
/// the default branch only: a branch must not mint keys, while a tick may be
/// committed on a detached HEAD.
Future<int> runSync({
  required Config config,
  required PlaneClient api,
  required File roadmap,
  required File cache,
  required String sha,
  required String branch,
  required bool holdsDefault,
  required bool apply,
  required bool noCreate,
  required DateTime now,
  required StringSink out,
}) async {
  if (apply && !holdsDefault) {
    throw StateError('refusing: this checkout ($branch) does not hold all of origin/${config.defaultBranch}');
  }
  if (apply && !noCreate && branch != config.defaultBranch) {
    throw StateError('refusing: a creating apply runs on ${config.defaultBranch}, this is $branch');
  }
  final id = config.identifier;
  final text = roadmap.readAsStringSync();
  final boxes = parseRoadmap(config, text);
  final remembered = readCache(cache);
  final lines = text.split('\n');
  final newKeys = <int, String>{}; // sequence id -> the line as it was read
  var changes = 0;
  var failures = 0;

  final ctx = Context(config, api, now);
  try {
    await ctx.load();
    ctx.requireSetup(boxes);
    final bySeq = {for (final it in ctx.items) it.sequence: it};
    final keys = boxes.map((b) => b.key).nonNulls.toList();
    final doubled = {
      for (final k in keys)
        if (keys.where((x) => x == k).length > 1) k,
    };

    for (final box in boxes) {
      final wantState = desiredState(box);
      final phaseCycle = ctx.cycleId[box.phase];
      final phaseClosed = ctx.closedCycles.contains(phaseCycle);
      final wantCycle = targetCycle(
        phaseCycleId: phaseCycle,
        phaseClosed: phaseClosed,
        open: wantState == 'Todo',
        currentCycleId: ctx.currentCycleId,
      );
      final desc = descriptionHtml(config, box, sha);

      if (box.key != null) {
        final name = '$id-${box.key}';
        final it = bySeq[box.key];
        if (doubled.contains(box.key)) {
          out.writeln('! L${box.lineIndex + 1} carries $name, as another line does');
          failures++;
          continue;
        }
        if (it == null) {
          out.writeln('! L${box.lineIndex + 1} carries $name but Plane has no such item');
          failures++;
          continue;
        }
        final patch = <String, Object>{};
        if (ctx.stateName[it.stateId] != wantState) {
          patch['state'] = ctx.stateId[wantState]!;
          out.writeln('~ $name ${ctx.stateName[it.stateId]} -> $wantState  (${box.title})');
        }
        if (remembered[name] != box.body) {
          patch['description_html'] = desc;
          if (!patch.containsKey('state')) out.writeln('~ $name description  (${box.title})');
        }
        final moveCycle = wantCycle != null && it.cycleId != wantCycle;
        if (moveCycle) {
          out.writeln('~ $name cycle ${ctx.cycleName[it.cycleId] ?? '-'} -> ${ctx.cycleName[wantCycle]}');
        }
        if (patch.isEmpty && !moveCycle) continue;
        changes++;
        if (!apply) continue;
        try {
          if (patch.isNotEmpty) {
            await api.patch('/issues/${it.id}/', patch);
            remembered[name] = box.body;
          }
          if (moveCycle) {
            await api.post('/cycles/$wantCycle/cycle-issues/', {'issues': [it.id]});
            it.cycleId = wantCycle;
          }
        } on Object catch (e) {
          failures++;
          out.writeln('  ! $name: $e');
        }
        continue;
      }

      // An unkeyed line: a new item (unless --no-create).
      final module = defaultModule(config, box.id, box.phase);
      // A closed phase with no cycle to go to: the `cyc:` label carries the history.
      final cycleClosed = phaseClosed && wantCycle == null;
      final cycleText = wantCycle == null ? '${box.phase} (closed)' : ctx.cycleName[wantCycle];
      out.writeln('+ L${box.lineIndex + 1} [$wantState] $cycleText / ${module ?? '-'}  ${box.title}');
      if (apply && noCreate) continue;
      changes++;
      if (!apply) continue;
      try {
        final labels = <String>[
          for (final n in creationLabelNames(isGate: box.isGate, phase: box.phase, cycleClosed: cycleClosed))
            await ctx.ensureLabel(n),
        ];
        final created = await api.post('/issues/', {
          'name': box.title,
          'state': ctx.stateId[wantState],
          'labels': labels,
          'description_html': desc,
        }) as Map;
        final issue = created['id'] as String;
        final seq = created['sequence_id'] as int;
        // The key first: a failure below must never leave a created item unkeyed.
        newKeys[seq] = lines[box.lineIndex];
        remembered['$id-$seq'] = box.body;
        out.writeln('  created $id-$seq');
        // The module before the cycle: it is set here or never, the cycle heals on the next run.
        if (module != null) {
          await api.post('/modules/${ctx.moduleId[module]}/module-issues/', {'issues': [issue]});
        }
        if (wantCycle != null) {
          await api.post('/cycles/$wantCycle/cycle-issues/', {'issues': [issue]});
        }
      } on Object catch (e) {
        failures++;
        out.writeln('  ! L${box.lineIndex + 1}: $e');
      }
    }

    final keyed = keys.toSet();
    final orphans = ctx.items.where((it) => !keyed.contains(it.sequence)).toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    if (orphans.isNotEmpty) {
      out.writeln('Plane items with no keyed line (left alone): ${orphans.length}');
      for (final it in orphans) {
        out.writeln('  $id-${it.sequence} [${ctx.stateName[it.stateId]}] ${it.name}');
      }
    }
    out.writeln(
      '${apply ? 'applied' : 'pending'}: $changes change(s), $failures failure(s); ${api.calls} API call(s)',
    );
    if (failures > 0) return 2;
    return apply || changes == 0 ? 0 : 1;
  } finally {
    // Whatever happened above, what was created is keyed and what was patched is remembered.
    if (apply) {
      if (newKeys.isNotEmpty) {
        // Against the file as it is now: an apply takes minutes, and the file may have moved.
        final current = roadmap.readAsStringSync().split('\n');
        newKeys.forEach((seq, line) {
          final at = current.indexOf(line);
          if (at < 0) {
            out.writeln('! the line changed during the run: add $id-$seq by hand: $line');
          } else {
            current[at] = lineWithKey(config, line, seq);
          }
        });
        roadmap.writeAsStringSync(current.join('\n'));
        out.writeln('ROADMAP.md: new keys written; commit it.');
      }
      writeCache(cache, remembered);
    }
  }
}

/// Creates what is missing, by name; changes and deletes nothing.
Future<int> runSetup({
  required Config config,
  required PlaneClient api,
  required StringSink out,
}) async {
  await checkProject(config, api);
  final cycles = (await api.all('/cycles/')).map((c) => c['name']).toSet();
  final modules = (await api.all('/modules/')).map((m) => m['name']).toSet();
  final labels = (await api.all('/labels/')).map((l) => l['name']).toSet();
  var changes = 0;
  for (final c in config.cycles) {
    if (cycles.contains(c.name)) {
      out.writeln('= cycle ${c.name}');
      continue;
    }
    await api.post('/cycles/', {
      'name': c.name,
      'start_date': c.start,
      'end_date': c.end,
      'description': c.description,
    });
    changes++;
    out.writeln('+ cycle ${c.name} ${c.start}..${c.end}');
  }
  for (final name in config.modules) {
    if (modules.contains(name)) {
      out.writeln('= module $name');
      continue;
    }
    await api.post('/modules/', {'name': name});
    changes++;
    out.writeln('+ module $name');
  }
  for (final e in config.labels.entries) {
    if (labels.contains(e.key)) {
      out.writeln('= label ${e.key}');
      continue;
    }
    await api.post('/labels/', {'name': e.key, 'color': e.value});
    changes++;
    out.writeln('+ label ${e.key}');
  }
  out.writeln('setup: $changes change(s)');
  return 0;
}

Future<int> _run(List<String> args) async {
  final cmd = parseCommand(args);
  final config = Config.parse(File(configFile).readAsStringSync());
  final main = await findMainClone();
  await requireIgnored(main);
  final api = PlaneApi(await readKey(File('$main/$keyFile')), base: config.projectUrl);
  try {
    if (cmd.command == 'setup') return await runSetup(config: config, api: api, out: stdout);
    return await runSync(
      config: config,
      api: api,
      roadmap: File(roadmapPath),
      cache: File('$main/$cacheFile'),
      sha: await _git(['rev-parse', 'HEAD']),
      branch: await _git(['rev-parse', '--abbrev-ref', 'HEAD']),
      holdsDefault: await holdsRemoteBranch(config.defaultBranch),
      apply: cmd.command == 'apply',
      noCreate: cmd.noCreate,
      now: DateTime.now(),
      out: stdout,
    );
  } finally {
    api.close();
  }
}

Future<void> main(List<String> args) async {
  try {
    exitCode = await _run(args);
  } on ArgumentError catch (e) {
    stderr.writeln('plane_sync: ${e.message}');
    stderr.writeln('usage: plane_sync.dart check | apply [--no-create] | setup');
    exitCode = 2;
  } on Object catch (e) {
    stderr.writeln('plane_sync: $e');
    exitCode = 2;
  }
}
