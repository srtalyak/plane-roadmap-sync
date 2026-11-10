import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/plane_sync.dart';

final demo = Config.parse(File('example/plane-sync.json').readAsStringSync());
final _fixture = File('example/ROADMAP.md').readAsStringSync();

const _ids = [
  'P0-A', 'P0-D', 'P0-I', 'G0', //
  'P1-01', 'P1-05', 'P1-07', 'G1',
  'P2-17',
  null, 'G3',
  'P4-01', 'P4-04',
];

/// Plane in memory: every write is recorded as `METHOD path`.
class FakePlane extends PlaneClient {
  FakePlane({
    String? identifier,
    String? id,
    List<Map<String, dynamic>>? cycles,
    List<String>? modules,
    List<String>? labels,
    List<Map<String, dynamic>>? issues,
  })  : identifier = identifier ?? demo.identifier,
        id = id ?? demo.projectId,
        cycles = cycles ?? _openCycles(),
        modules = modules ?? List.of(demo.modules),
        labels = labels ?? ['gate'],
        issues = issues ?? [];

  final String identifier;
  final String id;
  final List<Map<String, dynamic>> cycles;
  final List<String> modules;
  final List<String> labels;
  final List<Map<String, dynamic>> issues;
  final writes = <String>[];
  final bodies = <String, List<Object?>>{};

  /// Runs after each created issue: the world moving under a long run.
  void Function()? onCreate;

  /// Issue id -> cycle id.
  final cycleOf = <String, String>{};

  /// Throws on the first write whose `METHOD path` contains this text.
  String? failOn;
  int _seq = 100;

  @override
  int get calls => writes.length;

  @override
  Future<dynamic> send(String method, String path, [Object? body]) async {
    final clean = path.split('?').first;
    if (method == 'GET') return _read(clean);
    final call = '$method $clean';
    if (failOn != null && call.contains(failOn!)) {
      throw HttpException('$call -> 500');
    }
    writes.add(call);
    (bodies[call] ??= []).add(body);
    final map = body as Map;
    if (clean == '/issues/') {
      final seq = ++_seq;
      final row = {
        'id': 'issue-$seq',
        'sequence_id': seq,
        'name': map['name'],
        'state': map['state'],
      };
      issues.add(row);
      onCreate?.call();
      return row;
    }
    if (method == 'PATCH' && clean.startsWith('/issues/')) {
      final row = issues.firstWhere((r) => clean == '/issues/${r['id']}/');
      if (map.containsKey('name')) row['name'] = map['name'];
      if (map.containsKey('state')) row['state'] = map['state'];
    } else if (clean.endsWith('/cycle-issues/')) {
      final cycle = clean.split('/')[2];
      for (final issue in map['issues'] as List) {
        cycleOf[issue as String] = cycle;
      }
    } else if (clean == '/cycles/') {
      cycles.add({'id': 'c-${map['name']}', ...map.cast<String, dynamic>()});
    } else if (clean == '/modules/') {
      modules.add(map['name'] as String);
    } else if (clean == '/labels/') {
      labels.add(map['name'] as String);
      return {'id': 'label-${map['name']}'};
    }
    return {};
  }

  dynamic _read(String path) {
    if (path == '/') return {'id': id, 'identifier': identifier};
    if (path == '/states/') {
      return [
        for (final s in const ['Backlog', 'Todo', 'In Progress', 'Done', 'Cancelled'])
          {'id': 'state-$s', 'name': s},
      ];
    }
    if (path == '/labels/') {
      return [
        for (final l in labels) {'id': 'label-$l', 'name': l},
      ];
    }
    if (path == '/modules/') {
      return [
        for (final m in modules) {'id': 'module-$m', 'name': m},
      ];
    }
    if (path == '/cycles/') return cycles;
    if (path == '/issues/') return issues;
    if (path.endsWith('/cycle-issues/')) {
      final cycle = path.split('/')[2];
      return [
        for (final issue in issues)
          if (cycleOf[issue['id']] == cycle) issue,
      ];
    }
    throw StateError('unrouted GET $path');
  }
}

List<Map<String, dynamic>> _openCycles() => [
      for (var i = 0; i < 5; i++)
        {
          'id': 'cycle-$i',
          'name': 'Phase $i',
          'start_date': '2030-01-0${i + 1}T00:00:00Z',
          'end_date': '2031-1${i % 2}-28T20:59:00Z',
        },
    ];

final _now = DateTime.parse('2030-01-10T12:00:00Z');

void main() {
  final boxes = parseRoadmap(demo, _fixture);

  group('the config', () {
    Map<String, dynamic> raw() =>
        jsonDecode(File('example/plane-sync.json').readAsStringSync()) as Map<String, dynamic>;

    test('builds the project URL', () {
      expect(demo.projectUrl,
          'https://plane.example.com/api/v1/workspaces/my-workspace/projects/00000000-0000-0000-0000-000000000000');
    });

    test('a missing key is refused by name', () {
      final bad = raw()..remove('projectId');
      expect(() => Config.parse(jsonEncode(bad)),
          throwsA(predicate((Object e) => '$e'.contains('projectId'))));
    });

    test('an unknown key is refused: a typo must not silently mean a default', () {
      final bad = raw()..['defaultBranh'] = 'dev';
      expect(() => Config.parse(jsonEncode(bad)),
          throwsA(predicate((Object e) => '$e'.contains('defaultBranh'))));
    });

    test('defaultBranch falls back to main', () {
      expect(Config.parse(jsonEncode(raw()..remove('defaultBranch'))).defaultBranch, 'main');
    });

    test('a module table may only name a listed module', () {
      final bad = raw();
      (bad['boxModules'] as Map)['P0-G'] = 'Nowhere';
      expect(() => Config.parse(jsonEncode(bad)),
          throwsA(predicate((Object e) => '$e'.contains('Nowhere'))));
    });

    test('labels must hold the gate label', () {
      final bad = raw()..['labels'] = <String, String>{};
      expect(() => Config.parse(jsonEncode(bad)), throwsFormatException);
    });

    test('a lowercase identifier is refused', () {
      final bad = raw()..['identifier'] = 'demo';
      expect(() => Config.parse(jsonEncode(bad)), throwsFormatException);
    });
  });

  group('the parser', () {
    test('finds one item per top-level line under a phase, in order', () {
      expect(boxes.map((b) => b.id), _ids);
      expect(boxes.map((b) => b.phase).toSet(), {'Phase 0', 'Phase 1', 'Phase 2', 'Phase 3', 'Phase 4'});
    });

    test('section 0 and the appendix hold no items', () {
      expect(boxes.where((b) => b.body.contains('ritual') || b.body.contains('appendix')), isEmpty);
    });

    test('nested lines and headings are never items', () {
      expect(boxes.where((b) => b.body.contains('nested') || b.body.contains('Another')), isEmpty);
      expect(boxes.where((b) => b.body.contains('P0-A to P0-I')), isEmpty);
      expect(boxes.where((b) => b.body.startsWith('#')), isEmpty);
    });

    test('reads the tick, the key and the line index', () {
      final d = boxes[1];
      expect(d.id, 'P0-D');
      expect(d.checked, isTrue);
      expect(d.key, 12);
      expect(d.body, isNot(contains('DEMO')));
      expect(boxes[0].key, isNull);
      expect(_fixture.split('\n')[d.lineIndex], contains('P0-D Repository'));
    });

    test('a foreign key form is not a key', () {
      final b = parseRoadmap(demo, '## Phase 0\n- [ ] x <!-- OTHER-3 -->\n').single;
      expect(b.key, isNull);
    });

    test('a CRLF file parses the same as an LF file', () {
      final crlf = parseRoadmap(demo, _fixture.replaceAll('\n', '\r\n'));
      expect(crlf.map((b) => b.id), _ids);
      expect(crlf.map((b) => b.key), boxes.map((b) => b.key));
      expect(crlf.map((b) => b.body), boxes.map((b) => b.body));
      expect(crlf.map((b) => b.lineIndex), boxes.map((b) => b.lineIndex));
    });

    test('marks the gates, and only the gates', () {
      expect(boxes.where((b) => b.isGate).map((b) => b.id), ['G0', 'G1', 'G3']);
    });
  });

  group('the key', () {
    test('is appended before a CR and parsed back', () {
      final keyed = lineWithKey(demo, '- [ ] **P0-A Records**\r', 16);
      expect(keyed, '- [ ] **P0-A Records** <!-- DEMO-16 -->\r');
      expect(parseRoadmap(demo, '## Phase 0\r\n$keyed\n').single.key, 16);
      expect(lineWithKey(demo, '- [ ] x', 3), '- [ ] x <!-- DEMO-3 -->');
    });
  });

  group('titles', () {
    String titleOf(String? id) => boxes.firstWhere((b) => b.id == id).title;

    test('a box keeps NAME - gloss without the estimate', () {
      expect(titleOf('P1-01'), 'P1-01 LOGIN - the sign-in form and the session');
      expect(titleOf('P1-07'), 'P1-07 DESIGN PASS 1 - the first real screens');
      expect(titleOf('P2-17'), 'P2-17 STORE SET - listings, assets, forms');
    });

    test('a box with no gloss is its name, parentheses in the name kept', () {
      expect(titleOf('P1-05'), 'P1-05 SEARCH + FILTERS (the index on demo data)');
    });

    test('a leading or trailing parenthetical is dropped', () {
      expect(titleOf('P0-A'), 'P0-A Decisions and records');
      expect(titleOf('P0-D'), 'P0-D Repository and foundation');
      expect(titleOf('P0-I'), 'P0-I Tracker sync - this file mirrored to plane.example.com');
    });

    test('gate lines', () {
      expect(titleOf('G0'), 'Gate G0 - Day 0 done');
      expect(titleOf('G3'), 'Gate G3 - kill-or-scale (weeks 4-6) - the ladder in docs/03 section 6 and docs/07 section 3');
    });

    test('a bold name ending in a colon loses the colon', () {
      expect(titleOf('P4-01'), startsWith('P4-01 SECOND MARKETS - new listings live'));
      expect(boxes.singleWhere((b) => b.id == null).title, 'Week 0 - Closed track with the team');
    });

    test('a clause break inside parentheses does not cut the gloss', () {
      expect(titleOf('P4-04'), contains('(primary e-mail = the store e-mail; approval'));
    });

    test('a line with no bold name is cut at 120 on a word boundary', () {
      final t = deriveTitle(('word ' * 40).trim());
      expect(t.length, lessThanOrEqualTo(123));
      expect(t, endsWith('word...'));
    });

    test('annotation blocks with nested parentheses are stripped whole', () {
      expect(stripAnnotations('A *(Done 2030-01-22 (PR #155 (squash)) ticked)* - B'), 'A  - B');
      expect(stripAnnotations('no block (plain parens) here'), 'no block (plain parens) here');
    });
  });

  group('state', () {
    RoadmapBox box(String line) => parseRoadmap(demo, '## Phase 1\n$line\n').single;

    test('ticked is Done', () {
      expect(desiredState(box('- [x] **P1-01 A**')), 'Done');
      expect(desiredState(box('- [X] **P1-01 A**')), 'Done');
    });

    test('unticked is Todo', () {
      expect(desiredState(box('- [ ] **P1-01 A**')), 'Todo');
    });

    test('SKIPPED, withdrawn and superseded on the line are Cancelled', () {
      expect(desiredState(box('- [ ] **P1-01 A** - SKIPPED 2030-02-01')), 'Cancelled');
      expect(desiredState(box('- [ ] **P1-01 A** *(withdrawn)*')), 'Cancelled');
      expect(desiredState(box('- [ ] **P1-01 A** *(Withdrawn)*')), 'Cancelled');
      expect(desiredState(box('- [ ] **P1-01 A** - superseded by P1-02')), 'Cancelled');
    });

    test('a tick wins over a cancel word', () {
      expect(desiredState(box('- [x] **P1-01 A** - superseded by P1-02')), 'Done');
    });

    test('lowercase skipped in prose is not a cancel word', () {
      expect(desiredState(box('- [ ] **P1-01 A** - skipped frames are counted')), 'Todo');
    });
  });

  group('the Team line', () {
    const tr = 'Çöp kutuları sokağa iniyor';
    const sentences = 'Kutular ekranın üstünden akar; İlk ışık öğle güneşi.';
    List<RoadmapBox> parse(String s) => parseRoadmap(demo, '## Phase 1\n$s');

    test('is the title and sentences of the box above it, split at the first |', () {
      final b = parse('- [ ] **P1-02 LANE** - bins (3 days) <!-- DEMO-12 -->\n'
              '  - **Team:** $tr | $sentences\n')
          .single;
      expect(b.team!.title, tr);
      expect(b.team!.sentences, sentences);
      expect(b.team!.lineIndex, 2);
      expect(b.displayTitle, tr);
      expect(b.title, 'P1-02 LANE - bins', reason: 'the technical title is untouched');
      expect(b.body, isNot(contains('Team')));
    });

    test('a box without one keeps its derived title', () {
      final b = parse('- [ ] **P1-02 LANE** - bins (3 days)\n  - **Goal:** x\n').single;
      expect(b.team, isNull);
      expect(b.teamLines, isEmpty);
      expect(b.displayTitle, 'P1-02 LANE - bins');
    });

    test('is found after other nested lines and after a blank line inside the block', () {
      final b = parse('- [ ] **P1-02 LANE** - bins\n  - **Goal:** x\n  - [ ] y\n\n  - **Team:** a | b\n').single;
      expect(b.team!.title, 'a');
    });

    test('never comes from the next box, a heading or an unindented line', () {
      final bs = parse('- [ ] **P1-02 LANE** - a\n- [ ] **P1-03 WAVES** - b\n  - **Team:** t | s\n');
      expect(bs[0].team, isNull);
      expect(bs[1].team!.title, 't');
      expect(parse('- [ ] **P1-02 LANE** - a\nText\n  - **Team:** t | s\n').single.team, isNull);
      expect(parse('- [ ] **P1-02 LANE** - a\n## Phase 2\n  - **Team:** t | s\n').single.team, isNull);
      expect(parse('- [ ] **P1-02 LANE** - a\n- **Team:** t | s\n').single.team, isNull,
          reason: 'a Team line is nested');
    });

    test('no | is a title only; a hyphen never splits; a second | stays in the sentences', () {
      final only = parse('- [ ] **P1-02 LANE**\n  - **Team:** e-posta ile - giriş yok\n').single.team!;
      expect(only.title, 'e-posta ile - giriş yok');
      expect(only.sentences, '');
      final two = parse('- [ ] **P1-02 LANE**\n  - **Team:**   a  |  b | c  \n').single.team!;
      expect(two.title, 'a');
      expect(two.sentences, 'b | c');
    });

    test('markdown is stripped and a long title is cut at 120 on a word boundary', () {
      final t = parse('- [ ] **P1-02 LANE**\n  - **Team:** **kalın** `kod` | *vurgu* metin\n').single.team!;
      expect(t.title, 'kalın kod');
      expect(t.sentences, 'vurgu metin');
      final long = List.filled(40, 'kelime').join(' ');
      final cut = parse('- [ ] **P1-02 LANE**\n  - **Team:** $long\n').single.team!.title;
      expect(cut.length, lessThanOrEqualTo(123));
      expect(cut, endsWith('kelime...'));
    });

    test('a CRLF file reads the same', () {
      final lf = parse('- [ ] **P1-02 LANE**\n  - **Team:** $tr | $sentences\n').single.team!;
      final crlf = parse('- [ ] **P1-02 LANE**\r\n  - **Team:** $tr | $sentences\r\n').single.team!;
      expect(crlf.title, lf.title);
      expect(crlf.sentences, lf.sentences);
      expect(crlf.raw, lf.raw);
    });

    test('its words never reach the cancel rule', () {
      for (final word in ['SKIPPED', 'withdrawn', 'superseded']) {
        final b = parse('- [ ] **P1-02 LANE** - bins\n  - **Team:** $word | $word\n').single;
        expect(desiredState(b), 'Todo', reason: word);
      }
    });

    test('two Team lines or an empty one is a problem, never a guess', () {
      final two = parse('- [ ] **P1-02 LANE**\n  - **Team:** a\n  - **Team:** b\n').single;
      expect(two.team, isNull);
      expect(two.teamProblem, contains('2 Team lines (L3, L4)'));
      for (final empty in ['', '   ', ' | sentences only']) {
        final b = parse('- [ ] **P1-02 LANE**\n  - **Team:**$empty\n').single;
        expect(b.team, isNull, reason: empty);
        expect(b.teamProblem, contains('no title'), reason: empty);
      }
      expect(parse('- [ ] **P1-02 LANE**\n').single.teamProblem, isNull);
    });

    test('the description: the sentences, then the box id and the permalink; HTML escaped', () {
      final b = parse('- [ ] **P1-02 LANE** - bins\n  - **Team:** $tr | a < b & $sentences\n').single;
      final html = descriptionHtml(demo, b, 'abcdef0123456789');
      final link = '${demo.repoUrl}/blob/abcdef0123456789/ROADMAP.md?plain=1#L2';
      expect(html, '<p>a &lt; b &amp; $sentences</p><p>P1-02 - ROADMAP.md L2 at abcdef01: <a href="$link">$link</a></p>');
      expect(html, isNot(contains('bins')), reason: 'the technical text stays in the repository');
      final titleOnly = descriptionHtml(demo, parse('- [ ] **P1-02 LANE**\n  - **Team:** t\n').single, 'abcdef0123456789');
      expect(titleOnly, startsWith('<p>P1-02 - ROADMAP.md L2'));
      final noId = descriptionHtml(demo, parse('- [ ] **Week 0:** x\n  - **Team:** t | s\n').single, 'abcdef0123456789');
      expect(noId, startsWith('<p>s</p><p>ROADMAP.md L2'));
    });

    test('the cache text: the body alone without a Team line, the Team text with one', () {
      final plain = parse('- [ ] **P1-02 LANE** - bins\n').single;
      expect(syncedText(plain), plain.body);
      expect(hadTeam(syncedText(plain)), isFalse);
      final team = parse('- [ ] **P1-02 LANE** - bins\n  - **Team:** $tr | $sentences\n').single;
      expect(syncedText(team), '${team.body}\n**Team:** $tr | $sentences');
      expect(hadTeam(syncedText(team)), isTrue);
      expect(hadTeam(null), isFalse);
    });
  });

  group('the module', () {
    test('a box row wins over its phase', () {
      expect(defaultModule(demo, 'P0-A', 'Phase 0'), 'Ops');
      expect(defaultModule(demo, 'P0-G', 'Phase 0'), 'Backend');
    });

    test('a phase with no row leaves an unlisted box with no module', () {
      expect(defaultModule(demo, 'P2-20', 'Phase 2'), isNull);
      expect(defaultModule(demo, 'P2-17', 'Phase 2'), 'Launch');
    });

    test('a line with no id follows its phase', () {
      expect(defaultModule(demo, null, 'Phase 3'), 'Launch');
    });
  });

  group('cycles', () {
    test('a cycle past its end date is closed', () {
      final now = DateTime.parse('2030-02-20T00:00:00Z');
      expect(cycleIsClosed('2030-01-31T20:59:00Z', now), isTrue);
      expect(cycleIsClosed('2030-03-31T20:59:00Z', now), isFalse);
      expect(cycleIsClosed(null, now), isFalse);
    });

    test('an open item of a closed phase rolls forward; a closed one stays out', () {
      expect(targetCycle(phaseCycleId: 'p1', phaseClosed: false, open: true, currentCycleId: 'p1'), 'p1');
      expect(targetCycle(phaseCycleId: 'p2', phaseClosed: false, open: true, currentCycleId: 'p1'), 'p2',
          reason: 'an open phase keeps its own cycle, even a later one');
      expect(targetCycle(phaseCycleId: 'p0', phaseClosed: true, open: true, currentCycleId: 'p1'), 'p1');
      expect(targetCycle(phaseCycleId: 'p0', phaseClosed: true, open: false, currentCycleId: 'p1'), isNull);
    });

    test('the current cycle is the running one, else the next to start', () {
      final cycles = <Map<String, dynamic>>[
        {'id': 'p0', 'start_date': '2030-01-05T10:41:18.666102Z', 'end_date': '2030-01-14T20:59:00Z'},
        {'id': 'x', 'start_date': null, 'end_date': null},
        {'id': 'p2', 'start_date': '2030-02-19T21:00:01Z', 'end_date': '2030-03-31T20:59:00Z'},
      ];
      expect(currentCycleOf(cycles, _now), 'p0');
      expect(currentCycleOf(cycles, DateTime.parse('2030-01-20T00:00:00Z')), 'p2');
      expect(currentCycleOf(cycles, DateTime.parse('2030-06-01T00:00:00Z')), isNull);
    });

    test('the creation labels: gate on a gate, cyc: only for a closed cycle', () {
      expect(creationLabelNames(isGate: true, phase: 'Phase 1', cycleClosed: false), ['gate']);
      expect(creationLabelNames(isGate: false, phase: 'Phase 1', cycleClosed: true), ['cyc:Phase 1']);
      expect(creationLabelNames(isGate: false, phase: 'Phase 1', cycleClosed: false), isEmpty);
    });
  });

  test('the description carries the plain line and a permalink to the line', () {
    final html = descriptionHtml(demo, boxes[0], 'abcdef0123456789');
    expect(html, contains('<p>P0-A Decisions and records (done in the brief; verify, do not reopen)</p>'));
    expect(
      html,
      contains('github.com/your-name/your-repo/blob/abcdef0123456789/ROADMAP.md?plain=1#L${boxes[0].lineIndex + 1}'),
    );
    expect(html, isNot(contains('**')));
    expect(
      descriptionHtml(demo, parseRoadmap(demo, '## Phase 0\n- [ ] a < b & c\n').single, 'abcdef0123456789'),
      contains('a &lt; b &amp; c'),
    );
  });

  group('the arguments', () {
    test('parses the commands', () {
      expect(parseCommand([]).command, 'check');
      expect(parseCommand(['apply']).noCreate, isFalse);
      expect(parseCommand(['apply', '--no-create']).noCreate, isTrue);
      expect(parseCommand(['setup']).command, 'setup');
    });

    test('a misspelt flag is refused: it must never fall through to creation', () {
      expect(() => parseCommand(['apply', '--no-creat']), throwsArgumentError);
      expect(() => parseCommand(['adopt']), throwsArgumentError);
    });
  });

  group('the main clone', () {
    test('is the parent of the common git dir', () {
      expect(mainCloneOf('C:/x/app/.git'), 'C:/x/app');
      expect(mainCloneOf('/x/app/.git\n'), '/x/app');
    });

    test('anything else is refused', () {
      expect(() => mainCloneOf('C:/x/bare.git'), throwsStateError);
    });
  });

  group('the secrets folder', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('plane_ignore_test');
      Process.runSync('git', ['init', '-q'], workingDirectory: dir.path);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('a repo that does not ignore it is refused: the token must never be committed', () async {
      await expectLater(requireIgnored(dir.path), throwsStateError);
    });

    test('an ignored one passes', () async {
      File('${dir.path}/.gitignore').writeAsStringSync('secrets/\n');
      await requireIgnored(dir.path);
    });
  });

  group('a real worktree', () {
    late _Clone clone;
    setUp(() => clone = _Clone());
    tearDown(() => clone.dispose());

    test('reaches the token in the main clone, with no copy of its own', () async {
      clone.writeToken();
      final worktree = clone.addWorktree();
      final main = await findMainClone(worktree);
      // A boolean on purpose: a failure here must never print what it read.
      expect(await readKey(File('$main/$keyFile')) == 'fake', isTrue);
      expect(File('$worktree/$keyFile').existsSync(), isFalse);
    });

    test('holds the branch when it is in its history', () async {
      clone.git(['update-ref', 'refs/remotes/origin/main', 'HEAD']);
      final worktree = clone.addWorktree();
      expect(await holdsRemoteBranch('main', worktree), isTrue);
      clone.gitIn(worktree, ['commit', '--allow-empty', '-m', 'a tick']);
      expect(await holdsRemoteBranch('main', worktree), isTrue);
    });

    test('a checkout behind the branch does not hold it', () async {
      final behind = clone.addWorktree();
      clone.git(['commit', '--allow-empty', '-m', 'main moved']);
      clone.git(['update-ref', 'refs/remotes/origin/main', 'HEAD']);
      expect(await holdsRemoteBranch('main', behind), isFalse);
    });

    test('asks about the named branch, not main', () async {
      final behind = clone.addWorktree();
      clone.git(['update-ref', 'refs/remotes/origin/main', 'HEAD']);
      clone.git(['commit', '--allow-empty', '-m', 'develop moved']);
      clone.git(['update-ref', 'refs/remotes/origin/develop', 'HEAD']);
      expect(await holdsRemoteBranch('main', behind), isTrue);
      expect(await holdsRemoteBranch('develop', behind), isFalse);
    });

    test('no such ref holds nothing', () async {
      expect(await holdsRemoteBranch('main', clone.path), isFalse);
    });
  });

  group('the sync', () {
    late Directory dir;
    late File roadmap;
    late File cache;
    late StringBuffer out;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('plane_sync_test');
      roadmap = File('${dir.path}/ROADMAP.md');
      cache = File('${dir.path}/cache.json');
      out = StringBuffer();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<int> run(
      FakePlane plane,
      String text, {
      bool apply = false,
      bool noCreate = false,
      String branch = 'main',
      bool holdsDefault = true,
      Config? config,
    }) {
      roadmap.writeAsStringSync(text);
      return runSync(
        config: config ?? demo,
        api: plane,
        roadmap: roadmap,
        cache: cache,
        sha: 'abcdef0123456789',
        branch: branch,
        holdsDefault: holdsDefault,
        apply: apply,
        noCreate: noCreate,
        now: _now,
        out: out,
      );
    }

    const two = '## Phase 1\n- [ ] **P1-01 ONE** - a (3 days)\n- [ ] **Gate G1** - the read\n';

    test('the guard refuses another project before any write', () async {
      for (final plane in [FakePlane(identifier: 'OTHER'), FakePlane(id: 'other')]) {
        await expectLater(run(plane, two, apply: true), throwsStateError);
        expect(plane.writes, isEmpty);
      }
    });

    test('check lists every line as pending, writes nothing, exits 1', () async {
      final plane = FakePlane();
      expect(await run(plane, two), 1);
      expect(plane.writes, isEmpty);
      expect(roadmap.readAsStringSync(), two);
      expect(cache.existsSync(), isFalse);
      expect(out.toString(), contains('pending: 2 change(s), 0 failure(s)'));
    });

    test('check on a project in sync exits 0', () async {
      final plane = FakePlane(issues: [
        {'id': 'i1', 'sequence_id': 1, 'name': 'x', 'state': 'state-Todo'},
      ]);
      const keyed = '## Phase 1\n- [ ] **P1-01 ONE** <!-- DEMO-1 -->\n';
      cache.writeAsStringSync(jsonEncode({'DEMO-1': '**P1-01 ONE**'}));
      plane.cycleOf['i1'] = 'cycle-1';
      expect(await run(plane, keyed), 0);
      expect(out.toString(), contains('pending: 0 change(s)'));
    });

    test('apply behind the remote default branch is refused before any call, on it too', () async {
      final plane = FakePlane();
      for (final branch in ['main', 'feature/x', 'HEAD']) {
        for (final noCreate in [true, false]) {
          await expectLater(
            run(plane, two, apply: true, noCreate: noCreate, branch: branch, holdsDefault: false),
            throwsStateError,
          );
        }
      }
      expect(plane.writes, isEmpty);
    });

    test('check behind the remote default branch still reads', () async {
      expect(await run(FakePlane(), two, holdsDefault: false), 1);
    });

    test('a checkout holding the default branch mirrors keyed lines off it', () async {
      final plane = FakePlane(issues: [
        {'id': 'i1', 'sequence_id': 1, 'name': 'x', 'state': 'state-Todo'},
      ]);
      plane.cycleOf['i1'] = 'cycle-1';
      cache.writeAsStringSync(jsonEncode({'DEMO-1': '**P1-01 ONE**'}));
      const ticked = '## Phase 1\n- [x] **P1-01 ONE** <!-- DEMO-1 -->\n';
      expect(await run(plane, ticked, apply: true, noCreate: true, branch: 'HEAD'), 0);
      expect(plane.writes, ['PATCH /issues/i1/']);
    });

    test('a creating apply stays on the default branch, whatever the checkout holds', () async {
      final plane = FakePlane();
      await expectLater(run(plane, two, apply: true, branch: 'HEAD'), throwsStateError);
      await expectLater(run(plane, two, apply: true, branch: 'feature/x'), throwsStateError);
      expect(plane.writes, isEmpty);
    });

    test('the guards follow the configured default branch', () async {
      final raw = jsonDecode(File('example/plane-sync.json').readAsStringSync()) as Map;
      final develop = Config.parse(jsonEncode({...raw, 'defaultBranch': 'develop'}));
      final plane = FakePlane();
      await expectLater(
        run(plane, two, apply: true, branch: 'main', config: develop),
        throwsA(predicate((e) => '$e'.contains('runs on develop'))),
      );
      await expectLater(
        run(plane, two, apply: true, branch: 'develop', holdsDefault: false, config: develop),
        throwsA(predicate((e) => '$e'.contains('origin/develop'))),
      );
      expect(plane.writes, isEmpty);
      expect(await run(plane, two, apply: true, branch: 'develop', config: develop), 0);
      expect(plane.writes, isNotEmpty);
    });

    test('check is allowed on any branch', () async {
      expect(await run(FakePlane(), two, branch: 'feature/x'), 1);
    });

    test('apply --no-create writes nothing for unkeyed lines', () async {
      final plane = FakePlane();
      expect(await run(plane, two, apply: true, noCreate: true), 0);
      expect(plane.writes, isEmpty);
      expect(roadmap.readAsStringSync(), two);
    });

    test('apply creates the item with its state, title, cycle, module, gate label and key', () async {
      final plane = FakePlane();
      expect(await run(plane, two, apply: true), 0);
      expect(plane.writes.where((w) => w == 'POST /issues/'), hasLength(2));
      final first = plane.bodies['POST /issues/']!.first as Map;
      expect(first['name'], 'P1-01 ONE - a');
      expect(first['state'], 'state-Todo');
      expect(first['labels'], isEmpty);
      final gate = plane.bodies['POST /issues/']!.last as Map;
      expect(gate['labels'], ['label-gate']);
      expect(plane.writes, contains('POST /cycles/cycle-1/cycle-issues/'));
      expect(plane.writes, contains('POST /modules/module-Core/module-issues/'));
      final text = roadmap.readAsStringSync();
      expect(text, contains('(3 days) <!-- DEMO-101 -->\n'));
      expect(text, contains('the read <!-- DEMO-102 -->\n'));
      expect(jsonDecode(cache.readAsStringSync()), containsPair('DEMO-101', '**P1-01 ONE** - a (3 days)'));
    });

    test('a CRLF file stays CRLF and every other line stays byte-identical', () async {
      await run(FakePlane(), two.replaceAll('\n', '\r\n'), apply: true);
      expect(
        roadmap.readAsStringSync(),
        '## Phase 1\r\n- [ ] **P1-01 ONE** - a (3 days) <!-- DEMO-101 -->\r\n'
        '- [ ] **Gate G1** - the read <!-- DEMO-102 -->\r\n',
      );
    });

    test('a failure after creation leaves the created item keyed and cached', () async {
      final plane = FakePlane()..failOn = '/cycle-issues/';
      expect(await run(plane, two, apply: true), 2);
      expect(roadmap.readAsStringSync(), contains('<!-- DEMO-101 -->'));
      expect(jsonDecode(cache.readAsStringSync()), contains('DEMO-101'));
    });

    test('a crash mid-run still writes the keys and the cache', () async {
      roadmap.writeAsStringSync(two);
      await expectLater(
        runSync(
          config: demo,
          api: FakePlane(),
          roadmap: roadmap,
          cache: cache,
          sha: 'abcdef0123456789',
          branch: 'main',
          holdsDefault: true,
          apply: true,
          noCreate: false,
          now: _now,
          out: _CrashingSink('Gate G1'),
        ),
        throwsA(isA<_Crash>()),
      );
      expect(roadmap.readAsStringSync(), contains('<!-- DEMO-101 -->'));
      expect(jsonDecode(cache.readAsStringSync()), contains('DEMO-101'));
    });

    test('an edit made during the run survives the key write-back', () async {
      final plane = FakePlane();
      plane.onCreate = () {
        final now = roadmap.readAsStringSync();
        if (!now.contains('Added meanwhile')) {
          roadmap.writeAsStringSync('$now- [ ] **P1-09 NEW** - Added meanwhile\n');
        }
      };
      await run(plane, two, apply: true);
      final text = roadmap.readAsStringSync();
      expect(text, contains('Added meanwhile'));
      expect(text, contains('(3 days) <!-- DEMO-101 -->'));
      expect(text, contains('the read <!-- DEMO-102 -->'));
    });

    test('a key whose line changed during the run is reported, never dropped silently', () async {
      final plane = FakePlane();
      plane.onCreate = () {
        roadmap.writeAsStringSync(roadmap.readAsStringSync().replaceFirst('- a (3 days)', '- b (3 days)'));
      };
      await run(plane, two, apply: true);
      expect(out.toString(), contains('add DEMO-101 by hand'));
      expect(roadmap.readAsStringSync(), contains('- b (3 days)'));
    });

    test('the module goes first: it is set at creation only, the cycle heals on the next run', () async {
      final plane = FakePlane()..failOn = '/cycle-issues/';
      await run(plane, two, apply: true);
      expect(plane.writes, contains('POST /modules/module-Core/module-issues/'));
    });

    test('a keyed line: state, description and cycle follow, title and module do not', () async {
      final plane = FakePlane(issues: [
        {'id': 'i7', 'sequence_id': 7, 'name': 'A hand title', 'state': 'state-Todo'},
      ]);
      const keyed = '## Phase 1\n- [x] **P1-01 ONE** - changed <!-- DEMO-7 -->\n';
      expect(await run(plane, keyed, apply: true), 0);
      expect(plane.writes, ['PATCH /issues/i7/', 'POST /cycles/cycle-1/cycle-issues/']);
      final patch = plane.bodies['PATCH /issues/i7/']!.single as Map;
      expect(patch.keys, unorderedEquals(['state', 'description_html']));
      expect(patch['state'], 'state-Done');
    });

    test('a second apply on an unchanged file writes nothing', () async {
      final plane = FakePlane();
      await run(plane, two, apply: true);
      final keyed = roadmap.readAsStringSync();
      final before = plane.writes.length;
      expect(await run(plane, keyed, apply: true), 0);
      expect(plane.writes, hasLength(before));
    });

    test('a key with no Plane item is a failure, never a re-creation', () async {
      final plane = FakePlane();
      const keyed = '## Phase 1\n- [ ] **P1-01 ONE** <!-- DEMO-9 -->\n';
      expect(await run(plane, keyed, apply: true), 2);
      expect(plane.writes, isEmpty);
      expect(out.toString(), contains('DEMO-9'));
    });

    test('a key on two lines is a failure and neither line is written', () async {
      final plane = FakePlane(issues: [
        {'id': 'i7', 'sequence_id': 7, 'name': 'x', 'state': 'state-Todo'},
      ]);
      const keyed = '## Phase 1\n- [x] **P1-01 A** <!-- DEMO-7 -->\n- [ ] **P1-02 B** <!-- DEMO-7 -->\n';
      expect(await run(plane, keyed, apply: true), 2);
      expect(plane.writes, isEmpty);
    });

    test('an item with no keyed line is left alone: the tool deletes nothing', () async {
      final plane = FakePlane(issues: [
        {'id': 'i5', 'sequence_id': 5, 'name': 'Orphan', 'state': 'state-Todo'},
      ]);
      await run(plane, two, apply: true);
      expect(plane.writes.where((w) => w.contains('i5')), isEmpty);
      expect(plane.writes.where((w) => w.startsWith('DELETE')), isEmpty);
      expect(out.toString(), contains('DEMO-5'));
    });

    test('a missing cycle, module or gate label stops the run: run setup first', () async {
      for (final plane in [
        FakePlane(cycles: _openCycles()..removeAt(1)),
        FakePlane(modules: ['Ops']),
        FakePlane(labels: []),
      ]) {
        await expectLater(run(plane, two, apply: true), throwsStateError);
        expect(plane.writes, isEmpty);
      }
    });

    test('closed phase: an open item rolls forward, a ticked one stays out with a cyc: label', () async {
      final cycles = _openCycles();
      cycles[1]['end_date'] = '2030-01-01T20:59:00Z';
      final plane = FakePlane(cycles: cycles);
      await run(plane, '## Phase 1\n- [ ] **P1-01 A**\n- [x] **P1-02 B**\n', apply: true);
      final open = plane.bodies['POST /issues/']!.first as Map;
      final done = plane.bodies['POST /issues/']!.last as Map;
      expect(open['labels'], isEmpty);
      expect(done['labels'], ['label-cyc:Phase 1']);
      expect(plane.writes.where((w) => w.contains('cycle-issues')), ['POST /cycles/cycle-0/cycle-issues/']);
      expect(plane.labels, contains('cyc:Phase 1'));
    });

    group('with a Team line', () {
      const boxLine = '- [ ] **P0-K Board for the team** - the board reads a soft title <!-- DEMO-59 -->';
      const body = '**P0-K Board for the team** - the board reads a soft title';
      const derived = 'P0-K Board for the team - the board reads a soft title';
      const title = 'Pano ekip için okunur oluyor';
      const sentences = "Her iş kutusunun altındaki kısa satır Plane'de başlık ve açıklama olur.";
      const team = '## Phase 0\n$boxLine\n  - **Team:** $title | $sentences\n';
      const plain = '## Phase 0\n$boxLine\n';

      FakePlane plane59({String name = derived}) {
        final plane = FakePlane(issues: [
          {'id': 'i59', 'sequence_id': 59, 'name': name, 'state': 'state-Todo'},
        ]);
        plane.cycleOf['i59'] = 'cycle-0';
        return plane;
      }

      /// The state before Team lines: the tool remembers the plain body.
      void cachedPlain() => cache.writeAsStringSync(jsonEncode({'DEMO-59': body}));

      test('check reports the title and the description, writes nothing, exits 1', () async {
        final plane = plane59();
        cachedPlain();
        expect(await run(plane, team), 1);
        expect(plane.writes, isEmpty);
        expect(out.toString(), contains('~ DEMO-59 title "$derived" -> "$title"'));
        expect(out.toString(), contains('~ DEMO-59 description'));
        expect(out.toString(), contains('pending: 1 change(s), 0 failure(s)'));
      });

      test('apply sends one PATCH with the title and the description; then nothing is pending', () async {
        final plane = plane59();
        cachedPlain();
        expect(await run(plane, team, apply: true), 0);
        expect(plane.writes, ['PATCH /issues/i59/']);
        final patch = plane.bodies['PATCH /issues/i59/']!.single as Map;
        expect(patch.keys, unorderedEquals(['name', 'description_html']));
        expect(patch['name'], title);
        expect(patch['description_html'], startsWith('<p>$sentences</p><p>P0-K - ROADMAP.md L2 at abcdef01: '));
        expect(plane.issues.single['name'], title);
        out.clear();
        expect(await run(plane, team), 0);
        expect(out.toString(), contains('pending: 0 change(s), 0 failure(s)'));
        expect(await run(plane, team, apply: true), 0);
        expect(plane.writes, hasLength(1));
      });

      test('a title renamed by hand in Plane is reported and put back', () async {
        final plane = plane59(name: 'A hand title');
        cache.writeAsStringSync(jsonEncode({'DEMO-59': '$body\n**Team:** $title | $sentences'}));
        expect(await run(plane, team), 1);
        expect(out.toString(), contains('~ DEMO-59 title "A hand title" -> "$title"'));
        expect(await run(plane, team, apply: true), 0);
        expect((plane.bodies['PATCH /issues/i59/']!.single as Map).keys, ['name']);
      });

      test('a change to the Team sentences re-sends the description only', () async {
        final plane = plane59(name: title);
        cache.writeAsStringSync(jsonEncode({'DEMO-59': '$body\n**Team:** $title | $sentences'}));
        expect(await run(plane, '## Phase 0\n$boxLine\n  - **Team:** $title | Yeni cümle.\n', apply: true), 0);
        final patch = plane.bodies['PATCH /issues/i59/']!.single as Map;
        expect(patch.keys, ['description_html']);
        expect(patch['description_html'], startsWith('<p>Yeni cümle.</p>'));
      });

      test('a removed Team line puts the derived title and the plain description back, once', () async {
        final plane = plane59(name: title);
        cache.writeAsStringSync(jsonEncode({'DEMO-59': '$body\n**Team:** $title | $sentences'}));
        expect(await run(plane, plain), 1);
        expect(out.toString(), contains('~ DEMO-59 title "$title" -> "$derived"'));
        expect(await run(plane, plain, apply: true), 0);
        final patch = plane.bodies['PATCH /issues/i59/']!.single as Map;
        expect(patch['name'], derived);
        expect(patch['description_html'], startsWith('<p>$derived</p>'));
        plane.issues.single['name'] = 'Renamed later by hand';
        expect(await run(plane, plain, apply: true), 0);
        expect(plane.writes, hasLength(1), reason: 'a plain line owns no title again');
      });

      test('no backfill: a plain keyed line is never retitled, and one Team line patches its item only', () async {
        final plane = FakePlane(issues: [
          {'id': 'i7', 'sequence_id': 7, 'name': 'A hand title', 'state': 'state-Todo'},
          {'id': 'i59', 'sequence_id': 59, 'name': derived, 'state': 'state-Todo'},
        ]);
        plane.cycleOf['i7'] = 'cycle-0';
        plane.cycleOf['i59'] = 'cycle-0';
        const other = '- [ ] **P0-J Hook from worktrees** - the hook <!-- DEMO-7 -->';
        cache.writeAsStringSync(jsonEncode({
          'DEMO-7': '**P0-J Hook from worktrees** - the hook',
          'DEMO-59': body,
        }));
        expect(await run(plane, '## Phase 0\n$other\n$boxLine\n'), 0, reason: 'before any Team line: in sync');
        expect(await run(plane, '## Phase 0\n$other\n$boxLine\n  - **Team:** $title | $sentences\n', apply: true), 0);
        expect(plane.writes, ['PATCH /issues/i59/']);
      });

      test('a new line is born with its Team title and description', () async {
        final plane = FakePlane();
        expect(await run(plane, '## Phase 0\n- [ ] **P0-K Board for the team** - x\n  - **Team:** $title | $sentences\n'),
            1);
        expect(out.toString(), contains('[Todo] Phase 0 / Ops  $title'));
        expect(await run(plane, roadmap.readAsStringSync(), apply: true), 0);
        final post = plane.bodies['POST /issues/']!.single as Map;
        expect(post['name'], title);
        expect(post['description_html'], startsWith('<p>$sentences</p><p>P0-K - '));
        out.clear();
        expect(await run(plane, roadmap.readAsStringSync()), 0, reason: 'what it was born with is remembered');
      });

      test('two Team lines fail the box, exit 2, and nothing of it is written', () async {
        final plane = plane59();
        cachedPlain();
        final twice = '$team  - **Team:** another | one\n';
        expect(await run(plane, twice), 2);
        expect(await run(plane, twice, apply: true), 2);
        expect(plane.writes, isEmpty);
        expect(out.toString(), contains('! L2 has 2 Team lines (L3, L4); keep one'));
        const unkeyed = '## Phase 0\n- [ ] **P0-K Board** - new\n  - **Team:**  \n';
        expect(await run(plane, unkeyed, apply: true), 2);
        expect(plane.writes, isEmpty, reason: 'an empty Team line creates nothing');
        expect(await run(plane, unkeyed, apply: true, noCreate: true), 0,
            reason: 'the hook skips an unkeyed line, so its Team line is not the hook\'s failure');
        expect(await run(plane, unkeyed), 2, reason: 'check still reports it');
      });
    });
  });

  group('setup', () {
    test('on a full project writes nothing and reports 0 changes', () async {
      final plane = FakePlane();
      final out = StringBuffer();
      expect(await runSetup(config: demo, api: plane, out: out), 0);
      expect(plane.writes, isEmpty);
      expect(out.toString(), contains('setup: 0 change(s)'));
    });

    test('on an empty project creates everything in the config; twice is idempotent', () async {
      final plane = FakePlane(cycles: [], modules: [], labels: []);
      await runSetup(config: demo, api: plane, out: StringBuffer());
      expect(plane.writes.where((w) => w == 'POST /cycles/'), hasLength(5));
      expect(plane.writes.where((w) => w == 'POST /modules/'), hasLength(4));
      expect(plane.writes.where((w) => w == 'POST /labels/'), hasLength(1));
      final first = plane.bodies['POST /cycles/']!.first as Map;
      expect(first['name'], 'Phase 0');
      expect(first['start_date'], '2030-01-01');
      expect(first['end_date'], '2030-01-31');
      final before = plane.writes.length;
      await runSetup(config: demo, api: plane, out: StringBuffer());
      expect(plane.writes, hasLength(before));
    });

    test('creates only what is missing', () async {
      final plane = FakePlane(modules: List.of(demo.modules)..remove('Ops'));
      final out = StringBuffer();
      await runSetup(config: demo, api: plane, out: out);
      expect(plane.writes, ['POST /modules/']);
      expect(out.toString(), contains('setup: 1 change(s)'));
    });

    test('the guard refuses another project before any write', () async {
      final plane = FakePlane(identifier: 'OTHER', cycles: [], modules: [], labels: []);
      await expectLater(runSetup(config: demo, api: plane, out: StringBuffer()), throwsStateError);
      expect(plane.writes, isEmpty);
    });
  });

  group('the HTTP client', () {
    late HttpServer server;
    final seen = <DateTime>[];
    final keys = <String?>[];
    final received = <String>[];
    late List<(int, String, Map<String, String>)> replies;

    setUp(() async {
      seen.clear();
      keys.clear();
      received.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        seen.add(DateTime.now());
        keys.add(req.headers.value('X-API-Key'));
        received.add(await utf8.decodeStream(req));
        final (status, body, headers) = replies.removeAt(0);
        if (status == 0) return; // Accepts and never answers.
        req.response.statusCode = status;
        headers.forEach(req.response.headers.set);
        req.response.add(utf8.encode(body));
        await req.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    PlaneApi api({Duration pace = Duration.zero}) =>
        PlaneApi('the-token-value', base: 'http://127.0.0.1:${server.port}', pace: pace);

    test('non-ASCII text goes out as UTF-8 and comes back whole', () async {
      const name = 'Çöp kutuları ğüşıöç İĞÜŞÖÇ ãõñ';
      replies = [(200, jsonEncode({'name': name}), {})];
      final client = api();
      expect(await client.patch('/issues/x/', {'name': name}), {'name': name});
      expect(received.single, jsonEncode({'name': name}));
      client.close();
    });

    test('a 429 retries after Retry-After', () async {
      replies = [
        (429, '', {'retry-after': '0'}),
        (200, '{"ok":true}', {}),
      ];
      final client = api();
      expect(await client.get('/'), {'ok': true});
      expect(seen, hasLength(2));
      expect(keys.first, 'the-token-value');
      client.close();
    });

    test('calls are paced', () async {
      replies = [(200, '{}', {}), (200, '{}', {}), (200, '{}', {})];
      final client = api(pace: const Duration(milliseconds: 300));
      final clock = Stopwatch()..start();
      await client.get('/');
      await client.get('/');
      await client.get('/');
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(600));
      client.close();
    });

    test('a silent server times out instead of hanging the commit', () async {
      replies = [(0, '', {})];
      final client = PlaneApi(
        'the-token-value',
        base: 'http://127.0.0.1:${server.port}',
        pace: Duration.zero,
        timeout: const Duration(milliseconds: 100),
      );
      await expectLater(client.get('/'), throwsA(isA<TimeoutException>()));
      client.close();
    });

    test('the default pace stays under 60 calls a minute', () {
      expect(defaultPace, const Duration(milliseconds: 1100));
    });

    test('an error names the status and never the token', () async {
      replies = [(401, 'no', {})];
      final client = api();
      await expectLater(
        client.get('/'),
        throwsA(predicate((Object e) => '$e'.contains('401') && !'$e'.contains('the-token-value'))),
      );
      client.close();
    });

    test('a list follows the pages', () async {
      replies = [
        (200, '{"results":[{"id":"a"}],"next_page_results":true,"next_cursor":"100:1:0"}', {}),
        (200, '{"results":[{"id":"b"}],"next_page_results":false}', {}),
      ];
      final client = api();
      expect((await client.all('/issues/')).map((r) => r['id']), ['a', 'b']);
      client.close();
    });
  });

  group('the token file', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('plane_key_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('reads PLANE_API_KEY', () async {
      final f = File('${dir.path}/plane.env')..writeAsStringSync('# note\nPLANE_API_KEY=abc\n');
      expect(await readKey(f), 'abc');
    });

    test('a missing file or key is reported by name, value never', () async {
      await expectLater(readKey(File('${dir.path}/none')), throwsStateError);
      final f = File('${dir.path}/plane.env')..writeAsStringSync('OTHER=secretvalue\n');
      await expectLater(
        readKey(f),
        throwsA(predicate((Object e) => '$e'.contains('PLANE_API_KEY') && !'$e'.contains('secretvalue'))),
      );
    });
  });

  group('the example', () {
    test('every line has a module', () {
      for (final b in boxes) {
        expect(demo.modules, contains(defaultModule(demo, b.id, b.phase)), reason: b.title);
      }
    });

    test('its Team line sits under a box, holds a title and is never cut', () {
      final withTeam = boxes.where((b) => b.teamLines.isNotEmpty).toList();
      expect(withTeam.map((b) => b.id), ['P1-01']);
      for (final b in withTeam) {
        expect(b.teamProblem, isNull, reason: b.title);
        expect(b.team!.title.length, lessThanOrEqualTo(120), reason: b.title);
        expect(b.team!.title, isNot(endsWith('...')), reason: b.title);
      }
    });

    test('every phase has a cycle', () {
      final names = demo.cycles.map((c) => c.name).toSet();
      expect(names, containsAll(boxes.map((b) => b.phase).toSet()));
    });
  });

  group('the hook', () {
    final hook = File('tool/git-hooks/post-commit').readAsStringSync();
    final code = hook.replaceAll(RegExp(r'^#.*$', multiLine: true), '');

    test('only ever runs apply with --no-create', () {
      expect(code, contains('apply --no-create'));
      expect(RegExp(r'apply(?! --no-create)').hasMatch(code), isFalse);
    });

    test('resolves dart from PATH, no hardcoded path', () {
      expect(hook, isNot(contains('C:/')));
      expect(hook, isNot(contains('dart.exe')));
    });

    test('survives an older dart on PATH: no pub, no package language version', () {
      expect(code, isNot(contains('dart run')));
      expect(code, contains('dart --packages='));
      expect(code, contains('"packages":[]'));
    });

    test('clears the git environment before the tool calls git', () {
      expect(hook, contains('unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE'));
    });

    test('is executable in the index: git skips it on macOS and Linux otherwise', () {
      final r = Process.runSync('git', ['ls-files', '-s', 'tool/git-hooks/post-commit']);
      expect(r.stdout as String, startsWith('100755'));
    });

    test('never blocks a commit', () {
      expect(hook.trimRight(), endsWith('exit 0'));
    });

    group('on a real commit', () {
      late _Clone clone;
      late String worktree;
      setUp(() {
        clone = _Clone()..installHook();
        worktree = clone.addWorktree();
      });
      tearDown(() => clone.dispose());

      test('mirrors the committing worktree, not the main clone', () {
        clone.writeToken();
        expect(clone.tick(worktree).exitCode, 0);
        final call = clone.dartCall!;
        expect(call, contains('apply --no-create'));
        expect(call, contains('- [x] **P0-X**'), reason: 'the main clone still holds the open line');
        expect(clone.log, contains('fake dart ran'));
      });

      test('still mirrors a commit in the main clone', () {
        clone.writeToken();
        expect(clone.tick(clone.path).exitCode, 0);
        expect(clone.dartCall, contains('- [x] **P0-X**'));
      });

      test('leaves no secrets in the worktree', () {
        clone.writeToken();
        clone.tick(worktree);
        expect(Directory('$worktree/secrets').existsSync(), isFalse);
      });

      test('does nothing without the token file, and the commit stands', () {
        Directory('${clone.path}/secrets').createSync();
        final before = clone.gitIn(worktree, ['rev-parse', 'HEAD']).stdout;
        expect(clone.tick(worktree).exitCode, 0);
        expect(clone.dartCall, isNull);
        expect(clone.gitIn(worktree, ['rev-parse', 'HEAD']).stdout, isNot(before));
      });

      test('a failing tool is reported, names the real log, and the commit stands', () {
        clone.writeToken();
        final before = clone.gitIn(worktree, ['rev-parse', 'HEAD']).stdout;
        final commit = clone.tick(worktree, dartExit: 2);
        expect(commit.exitCode, 0);
        expect('${commit.stdout}${commit.stderr}', contains('failed - see ${clone.path}/secrets/plane-sync.log'));
        expect(clone.gitIn(worktree, ['rev-parse', 'HEAD']).stdout, isNot(before));
      });

      test('ignores a commit that leaves ROADMAP.md alone', () {
        clone.writeToken();
        File('$worktree/other.txt').writeAsStringSync('x');
        clone.gitIn(worktree, ['add', 'other.txt']);
        expect(clone.commit(worktree, 'not a tick').exitCode, 0);
        expect(clone.dartCall, isNull);
      });
    });
  });
}

/// A throwaway clone with one open box, its worktrees beside it, and a `dart`
/// on PATH that records its call: nothing here can reach Plane.
class _Clone {
  _Clone() : _root = Directory.systemTemp.createTempSync('plane_hook_test') {
    Directory(path).createSync();
    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'test']);
    git(['config', 'user.email', 'test@example.com']);
    git(['config', 'commit.gpgsign', 'false']);
    File('$path/ROADMAP.md').writeAsStringSync('- [ ] **P0-X**\n');
    git(['add', 'ROADMAP.md']);
    git(['commit', '-q', '-m', 'first']);
    final dart = File('$_bin/dart')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'echo "\$*" > "\$FAKE_DART_CALL"\n'
        'cat ROADMAP.md >> "\$FAKE_DART_CALL"\n'
        'echo fake dart ran\n'
        'exit "\${FAKE_DART_EXIT:-0}"\n',
      );
    if (!Platform.isWindows) Process.runSync('chmod', ['+x', dart.path]);
  }

  final Directory _root;
  int _worktrees = 0;

  String get _base => _root.path.replaceAll(r'\', '/');
  String get path => '$_base/clone';
  String get _bin => '$_base/bin';
  File get _call => File('$_base/dart-call.txt');

  String? get dartCall => _call.existsSync() ? _call.readAsStringSync() : null;
  String get log => File('$path/secrets/plane-sync.log').readAsStringSync();

  ProcessResult gitIn(String dir, List<String> args, {int dartExit = 0}) => Process.runSync(
        'git',
        args,
        workingDirectory: dir,
        environment: {
          'PATH': '$_bin${Platform.isWindows ? ';' : ':'}${Platform.environment['PATH']}',
          'FAKE_DART_CALL': _call.path,
          'FAKE_DART_EXIT': '$dartExit',
        },
      );

  ProcessResult git(List<String> args) {
    final r = gitIn(path, args);
    if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
    return r;
  }

  void installHook() {
    git(['config', 'core.hooksPath', '${Directory.current.path}/tool/git-hooks'.replaceAll(r'\', '/')]);
  }

  void writeToken() {
    File('$path/$keyFile')
      ..createSync(recursive: true)
      ..writeAsStringSync('PLANE_API_KEY=fake\n');
  }

  /// Detached at HEAD, as a tick from a worktree is.
  String addWorktree() {
    final dir = '$_base/worktree${_worktrees++}';
    git(['worktree', 'add', '-q', '--detach', dir, 'HEAD']);
    return dir;
  }

  ProcessResult commit(String dir, String message, {int dartExit = 0}) =>
      gitIn(dir, ['commit', '-q', '-m', message], dartExit: dartExit);

  ProcessResult tick(String dir, {int dartExit = 0}) {
    File('$dir/ROADMAP.md').writeAsStringSync('- [x] **P0-X**\n');
    gitIn(dir, ['add', 'ROADMAP.md']);
    return commit(dir, 'tick', dartExit: dartExit);
  }

  void dispose() => _root.deleteSync(recursive: true);
}

class _Crash implements Exception {}

/// Throws on the first line holding [trigger]: a crash outside any item's try.
class _CrashingSink implements StringSink {
  _CrashingSink(this.trigger);
  final String trigger;

  @override
  void writeln([Object? obj = '']) {
    if ('$obj'.contains(trigger)) throw _Crash();
  }

  @override
  void write(Object? obj) {}

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {}

  @override
  void writeCharCode(int charCode) {}
}
