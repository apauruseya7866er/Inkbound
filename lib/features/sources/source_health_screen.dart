import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ui/settings_widgets.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/playback/search_source_prefs.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/source_health_store.dart';
import '../../core/playback/source_uninstaller.dart';
import '../../core/repository/source_repository.dart';
import '../search/bloc/search_bloc.dart' show SearchBloc;
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../core/ui/app_dialog.dart';
import '../../l10n/l10n.dart';

/// "Test sources" — probes every enabled source concurrently and shows, per
/// source, whether it's Working / Slow / Dead (with the reason). A probe asks
/// "does it RESPOND without error/timeout" (even 0 results = alive), NOT "does
/// it have this exact title". Results update [SourceHealthStore] so the live
/// search ordering benefits from a manual test too.
///
/// The CF "verifying" overlay never pops during probes: JS search routes through
/// the provider-manager `search` path (solver suppressed) and CloudStream search
/// goes through native `searchStatus` (bumps `CfClearance.searchDepth`).
class SourceHealthScreen extends StatefulWidget {
  const SourceHealthScreen({super.key});

  @override
  State<SourceHealthScreen> createState() => _SourceHealthScreenState();
}

/// One probe's live result. [running] while in flight; otherwise the resolved
/// outcome + measured response time.
class _ProbeResult {
  _ProbeResult({required this.id, required this.name});

  final String id;
  final String name;
  bool running = true;
  SourceOutcome? outcome;
  int? responseMs;
  int? resultCount;

  /// The first few search hits, kept so the deep check has something to open.
  ///
  /// More than one on purpose: a single title can legitimately have no chapters
  /// or episodes (a stub entry, or everything filtered out by language), and
  /// judging a whole source on that one pick is how a healthy source gets called
  /// broken.
  List<String> topUrls = const [];

  /// Deep check: did opening a title and listing its episodes/chapters work?
  /// Null when the deep check hasn't run (or couldn't).
  bool? deepOk;

  /// Why the deep check failed, in the user's words.
  String? deepNote;

  bool get isCloudStream => id.startsWith('cs:');
}

class _SourceHealthScreenState extends State<SourceHealthScreen> {
  SourceRepository get _repo => sl<SourceRepository>();
  SourceHealthStore get _health => sl<SourceHealthStore>();
  SearchSourcePrefs get _searchPrefs => sl<SearchSourcePrefs>();

  /// Several broad queries, tried in order until one returns hits.
  ///
  /// One fixed word was a false-negative machine: a source with nothing
  /// matching it answered with 0 results and got reported as fine. CloudStream's
  /// own provider tester does the same thing for the same reason — it tries a
  /// list and only calls search broken when EVERY query comes back empty.
  static const List<String> _probeQueries = ['one', 'the', 'love'];

  /// Deliberately shorter than [SearchBloc.sourceTimeout].
  ///
  /// Search caps ONE source the user is actively waiting on, so it can afford
  /// 60s. This screen probes every installed source, so a long cap just pins a
  /// worker slot on a host that isn't answering and starves the rest of the
  /// list. A source slower than this reads context.l10n.timedOut here and may still work
  /// in search — that's the honest trade, and it's why the label says timed out
  /// rather than dead.
  static const Duration _probeTimeout = Duration(seconds: 20);

  /// How many sources are probed at once.
  ///
  /// Every source used to be fired simultaneously — 70 concurrent probes, each
  /// now up to three requests, every one calling setState and rebuilding the
  /// whole list. Two runs overlapping made it ~140 and the UI stopped
  /// responding. A small pool keeps the work bounded no matter how many
  /// sources are installed.
  static const int _maxConcurrent = 6;

  /// Deep checks run far fewer at a time.
  ///
  /// A deep check calls `episodes()`, and for JS sources that executes the
  /// QuickJS runtime ON THE UI ISOLATE (the known open item in the perf notes).
  /// Six of those in flight left no room for the UI to draw and the screen
  /// stopped responding. Two keeps it usable; the real fix is moving that work
  /// off the UI isolate, which is a much bigger change than this screen.
  static const int _maxConcurrentDeep = 2;

  List<_ProbeResult> _results = const [];
  bool _testing = false;

  /// Whether the last run also opened a title from each source. Off by default:
  /// it's several extra requests per source, so it's an explicit choice.
  bool _deep = false;

  // ── removal ────────────────────────────────────────────────────────────────

  /// Multi-select mode. On, rows become checkboxes and the only action is the
  /// bulk delete — which is the point: a user clearing twenty rotted sources
  /// should confirm once, not twenty times.
  bool _selecting = false;

  /// Source ids ticked for removal. Never contains an id that can't be
  /// uninstalled ([SourceUninstaller.canUninstall]), so a Z-Mode row can never
  /// be ticked and there is no way to confirm a batch the uninstaller refuses.
  final Set<String> _selected = {};

  /// A removal batch is in flight. Guards the actions so a second tap can't
  /// start a second pass over the same ids mid-delete.
  bool _removing = false;

  bool get _isTv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  /// Whether this row is one the user would want gone: not a clean pass.
  ///
  /// Anything other than "search answered with hits AND (if the deep check ran)
  /// it opened something playable AND playback isn't failing" — so amber
  /// "no results" and "timed out" count, not just red. A timed-out source is
  /// slow rather than proven broken, which is why this is only what
  /// [_selectAllProblems] ticks — nothing is removed without the user seeing
  /// the list and confirming.
  bool _isProblem(_ProbeResult r) {
    if (r.running) return false;
    if (r.outcome != SourceOutcome.ok) return true;
    if (r.deepOk == false) return true;
    if (_health.playbackFailures(r.id) >= SourceHealthStore.deadAfterTitles) {
      return true;
    }
    return false;
  }

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      // Leaving the selection behind would silently re-apply it the next time
      // the mode is entered.
      if (!_selecting) _selected.clear();
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  /// Ticks every row that isn't a clean pass, leaving healthy ones alone.
  ///
  /// The whole reason multi-select exists: the rows worth deleting are the ones
  /// that need reading to find, and scrolling 160 sources ticking checkboxes is
  /// how a user gives up and leaves them installed. Stays out of the way after
  /// that — it only ticks, never removes.
  void _selectAllProblems() {
    setState(() {
      for (final r in _results) {
        if (_isProblem(r) && SourceUninstaller.canUninstall(r.id)) {
          _selected.add(r.id);
        }
      }
    });
  }

  /// Confirm-then-delete for a single row.
  Future<void> _confirmUninstallOne(_ProbeResult r) async {
    if (!SourceUninstaller.canUninstall(r.id)) return;
    final l10n = context.l10n;
    final ok = await AppDialog.confirm(
      context,
      title: l10n.uninstallNameQuestion(r.name),
      message: l10n.thisRemovesTheSourceFromYourInstalledList,
      confirmLabel: l10n.uninstall,
      destructive: true,
    );
    if (ok != true) return;
    await _removeSources([r.id]);
  }

  /// Confirm-then-delete for the whole selection. One confirmation for the
  /// batch, naming how many are going — never a silent bulk delete.
  Future<void> _confirmUninstallSelected() async {
    final ids = [
      for (final id in _selected)
        if (SourceUninstaller.canUninstall(id)) id,
    ];
    if (ids.isEmpty) return;
    final l10n = context.l10n;
    final ok = await AppDialog.confirm(
      context,
      title: l10n.uninstallSelectedSourcesQuestion(ids.length),
      message: l10n.uninstallSelectedSourcesMessage,
      confirmLabel: l10n.uninstall,
      destructive: true,
    );
    if (ok != true) return;
    await _removeSources(ids);
  }

  /// Removes [ids], drops their rows, and reports what happened.
  ///
  /// Sequential, not parallel: each ecosystem's delete shares per-source state
  /// — one Hive box, one manager, and for Mihon/Aniyomi a single APK behind
  /// every language copy — so two at once is how an interleaved half-delete
  /// happens. The batches are short and the work is local IO.
  ///
  /// A failure never stops the pass. One stubborn source must not strand the
  /// other nineteen the user asked to remove, so each is attempted and the
  /// successes are reported alongside the count that didn't go.
  Future<void> _removeSources(List<String> ids) async {
    if (ids.isEmpty || _removing) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _removing = true);

    final removed = <String>[];
    var failed = 0;
    for (final id in ids) {
      final res = await SourceUninstaller.uninstall(id);
      if (!res.ok) {
        failed++;
        continue;
      }
      removed.add(id);
      // The recorded health now describes a source that no longer exists, and
      // search skips sources the store calls dead — so leaving it behind would
      // have a reinstalled source silently skipped on its first search.
      await _health.clear(id);
      // Same reasoning for a search exclusion: clear it, or the source comes
      // back reinstalled and invisible to search with nothing explaining why.
      await _searchPrefs.setIncluded(id, true);
    }

    if (!mounted) return;
    setState(() {
      if (removed.isNotEmpty) {
        _results = [
          for (final r in _results)
            if (!removed.contains(r.id)) r,
        ];
      }
      _selected.removeAll(removed);
      _removing = false;
      // Nothing left to act on — don't strand the user in a mode with no
      // selection and no rows to pick from.
      if (_selected.isEmpty) _selecting = false;
    });

    final message = switch ((removed.length, failed)) {
      (0, final f) => l10n.uninstallFailedCount(f),
      (final n, 0) => l10n.uninstalledSourcesCount(n),
      (final n, final f) =>
        '${l10n.uninstalledSourcesCount(n)} · ${l10n.uninstallFailedCount(f)}',
    };
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runTests());
  }

  /// Probes every enabled source concurrently, updating each row + the store as
  /// results land.
  /// Bumped per run. A superseded run stops touching state (and stops taking
  /// new work) instead of racing the one that replaced it.
  int _runGen = 0;

  Future<void> _runTests({bool deep = false}) async {
    final gen = ++_runGen;
    final sources = _repo.loadedSources;
    setState(() {
      _testing = true;
      _deep = deep;
      _results = [
        for (final s in sources) _ProbeResult(id: s.id, name: s.name),
      ];
    });

    // Fixed-size worker pool over a shared cursor, so at most
    // [_maxConcurrent] probes are ever in flight.
    final queue = List<_ProbeResult>.of(_results);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (gen != _runGen || !mounted) return;
        final i = next++;
        if (i >= queue.length) return;
        await _probe(queue[i], deep: deep, gen: gen);
        // Hand the frame back between sources — without this a run of
        // synchronous provider work never lets the list repaint.
        await Future<void>.delayed(Duration.zero);
      }
    }

    await Future.wait([
      for (var i = 0; i < (deep ? _maxConcurrentDeep : _maxConcurrent); i++)
        worker(),
    ]);

    if (mounted && gen == _runGen) setState(() => _testing = false);
  }

  Future<void> _probe(
    _ProbeResult r, {
    required int gen,
    bool deep = false,
  }) async {
    final sw = Stopwatch()..start();
    SourceOutcome outcome = SourceOutcome.empty;
    int count = 0;
    var topUrls = const <String>[];

    // Try each query until one returns hits. A later success overrides an
    // earlier empty/failure — the source clearly works, the first word just
    // didn't match.
    for (final q in _probeQueries) {
      if (gen != _runGen) return; // superseded mid-probe; stop making requests
      try {
        final res = await _repo
            .searchStatus(q, sourceId: r.id)
            .timeout(
              _probeTimeout,
              onTimeout: () =>
                  (items: const <MediaItem>[], outcome: SourceOutcome.timeout),
            );
        outcome = res.outcome;
        if (res.items.isNotEmpty) {
          count = res.items.length;
          topUrls = [for (final i in res.items.take(3)) i.url];
          break;
        }
      } catch (_) {
        outcome = SourceOutcome.error;
      }
      // A hard failure is about the source, not the word — no point retrying.
      if (outcome == SourceOutcome.error ||
          outcome == SourceOutcome.blocked ||
          outcome == SourceOutcome.timeout) {
        break;
      }
    }
    sw.stop();
    if (gen != _runGen) return; // a newer run replaced this one
    // Records exactly what it always did, so search's ordering and skipping are
    // unchanged by anything on this screen.
    // ignore: unawaited_futures
    _health.record(r.id, outcome, responseMs: sw.elapsedMilliseconds);
    if (!mounted) return;
    setState(() {
      // Still spinning only when a deep check is about to run for this row;
      // otherwise the probe IS the result.
      r.running = deep && topUrls.isNotEmpty;
      r.outcome = outcome;
      r.responseMs = sw.elapsedMilliseconds;
      r.resultCount = count;
      r.topUrls = topUrls;
    });
    if (deep && topUrls.isNotEmpty) await _deepCheck(r, topUrls, gen);
  }

  /// Opens the first search hit and lists its episodes/chapters.
  ///
  /// This is the part a search-only probe can't answer: a source can search
  /// perfectly and still be unable to open anything, which is the difference
  /// between "responds" and "usable". CloudStream's tester goes further still
  /// and resolves video links; this stops at the episode list, which is the
  /// same check for every mode (anime episodes, manga and novel chapters all
  /// come back through `episodes`).
  Future<void> _deepCheck(_ProbeResult r, List<String> urls, int gen) async {
    bool ok = false;
    String? note;
    var opened = false;
    for (final url in urls) {
      if (gen != _runGen) return;
      try {
        final eps = await _repo
            .episodes(url, sourceId: r.id)
            .timeout(_probeTimeout, onTimeout: () => const []);
        opened = true;
        if (eps.isNotEmpty) {
          ok = true;
          note = '${eps.length} to play';
          break;
        }
      } catch (_) {
        // Try the next title before blaming the source.
      }
    }
    if (!ok) {
      note = opened ? 'opens, but lists nothing to play' : "can't open titles";
    }
    if (!mounted || gen != _runGen) return;
    setState(() {
      r.running = false;
      r.deepOk = ok;
      r.deepNote = note;
    });
  }

  // ── status presentation ────────────────────────────────────────────────────
  static const Color _green = Color(0xFF35C759);

  static const Color _amber = Color(0xFFE0A33A);

  /// The outcome as it actually was.
  ///
  /// This used to collapse to Working/Dead, which meant a Cloudflare-blocked
  /// source, a source that timed out, and a source returning nothing all wore a
  /// green tick — while the search screen, looking at the same store, called
  /// those same sources blocked or unreachable. Two screens, opposite answers.
  ///
  /// Green now means "you'll get results". Amber means "it answered, but you may
  /// get nothing out of it". Red means broken. Only red is [SourceHealth.dead]
  /// in the store, so search's skipping is untouched by this.
  ({Color color, IconData icon, String label}) _present(SourceOutcome o) =>
      switch (o) {
        SourceOutcome.ok => (
          color: _green,
          icon: Icons.check_circle_rounded,
          label: context.l10n.working,
        ),
        SourceOutcome.slow => (
          color: _amber,
          icon: Icons.hourglass_bottom_rounded,
          label: context.l10n.slow,
        ),
        SourceOutcome.empty => (
          color: _amber,
          icon: Icons.search_off_rounded,
          label: context.l10n.noResults,
        ),
        SourceOutcome.timeout => (
          color: _amber,
          icon: Icons.hourglass_empty_rounded,
          label: context.l10n.timedOut,
        ),
        SourceOutcome.blocked => (
          color: _amber,
          icon: Icons.shield_outlined,
          label: context.l10n.blocked,
        ),
        SourceOutcome.error => (
          color: AppColors.accent,
          icon: Icons.cancel_rounded,
          label: context.l10n.dead,
        ),
      };

  @override
  Widget build(BuildContext context) {
    // context.l10n.working means it returned results — not merely that it answered.
    final working = _results
        .where((r) => !r.running && r.outcome == SourceOutcome.ok)
        .length;
    final done = _results.where((r) => !r.running).length;
    final unusable = _results
        .where((r) => !r.running && r.deepOk == false)
        .length;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(
        // The title doubles as the selection counter, so the count is where the
        // user is already looking instead of in a second place.
        _selecting
            ? context.l10n.sourcesSelectedCount(_selected.length)
            : context.l10n.sourceHealth,
        actions: [
          if (_selecting)
            // Deliberately no second "delete" icon here. The bulk control is the
            // bottom bar, which carries the count; a duplicate in the app bar
            // gives the same destructive action two homes and no way to tell
            // which one the count refers to.
            IconButton(
              tooltip: context.l10n.selectAllProblems,
              icon: const Icon(Icons.playlist_add_check_rounded),
              color: AppColors.textPrimary,
              onPressed: _results.isEmpty || _removing
                  ? null
                  : _selectAllProblems,
            )
          else ...[
            IconButton(
              tooltip: 'Deep test (opens a title from each source)',
              icon: const Icon(Icons.biotech_outlined),
              color: _deep ? AppColors.accent : AppColors.textPrimary,
              // Live even mid-run. The screen kicks off a test on open, and
              // disabling this until that finished meant waiting out the whole
              // list before you could ask for the deeper one. Safe now that a new
              // run supersedes the old via [_runGen] instead of racing it.
              onPressed: () => _runTests(deep: true),
            ),
            IconButton(
              tooltip: context.l10n.selectSourcesToRemove,
              icon: const Icon(Icons.checklist_rounded),
              color: AppColors.textPrimary,
              // Available before the probes finish: the point of this mode is to
              // clear out sources that are dead, and the run that tells you
              // which those are is the thing making you wait.
              onPressed: _results.isEmpty ? null : _toggleSelecting,
            ),
            IconButton(
              tooltip: context.l10n.reTest,
              icon: const Icon(Icons.refresh_rounded),
              color: AppColors.textPrimary,
              onPressed: _testing ? null : _runTests,
            ),
          ],
        ],
      ),
      body: _results.isEmpty
          ? Center(
              child: Text(
                context.l10n.noEnabledSourcesToTest,
                style: AppText.body,
              ),
            )
          : RefreshIndicator(
              color: AppColors.accent,
              backgroundColor: AppColors.surface,
              onRefresh: _runTests,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                    child: Text(
                      _testing
                          ? '${_deep ? 'Deep t' : 'T'}esting '
                                '${_results.length} source'
                                '${_results.length == 1 ? '' : 's'}…'
                          : _selecting
                          ? context.l10n.selectSourcesToRemoveHint
                          : '$working of $done returned results.'
                                '${unusable > 0 ? ' $unusable opened nothing '
                                          'playable.' : ''}'
                                ' Amber answered but may give you nothing;'
                                ' only red is treated as dead.',
                      style: AppText.caption,
                    ),
                  ),
                  Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < _results.length; i++) ...[
                          if (i > 0)
                            const Divider(
                              height: 0.5,
                              thickness: 0.5,
                              color: AppColors.hairline,
                            ),
                          _HealthRow(
                            result: _results[i],
                            present: _present,
                            searchIncluded: _searchPrefs.isIncluded(
                              _results[i].id,
                            ),
                            playbackFails: _health.playbackFailures(
                              _results[i].id,
                            ),
                            selecting: _selecting,
                            selected: _selected.contains(_results[i].id),
                            onToggleSelected: () =>
                                _toggleSelected(_results[i].id),
                            // Every row offers removal, not just the broken
                            // ones: the user came here to clear out what isn't
                            // working, and making them learn this screen is the
                            // only place that can do it is a worse answer than
                            // an undo isn't.
                            onUninstall:
                                SourceUninstaller.canUninstall(_results[i].id)
                                ? () => _confirmUninstallOne(_results[i])
                                : null,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
      // Bulk action lives at the bottom, not in the app bar: it's the
      // destructive, thumb-reachable control, and the bar above keeps it
      // unambiguous that it applies to every ticked row. It stays put during the
      // removal instead of vanishing — the one control the user just pressed
      // should report its own progress, not disappear.
      bottomNavigationBar: _selecting && (_selected.isNotEmpty || _removing)
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: _isTv
                    ? TvListFocusable(
                        semanticLabel: context.l10n.uninstall,
                        onTap: _confirmUninstallSelected,
                        child: _BulkUninstallButton(
                          count: _selected.length,
                          removing: _removing,
                        ),
                      )
                    : _BulkUninstallButton(
                        count: _selected.length,
                        removing: _removing,
                        onPressed: _confirmUninstallSelected,
                      ),
              ),
            )
          : null,
    );
  }
}

/// Filled, full-width delete button for the bottom bar. Counts the selection so
/// the button states its own blast radius — "Uninstall" alone on a screen of
/// 160 rows is a claim about nothing.
class _BulkUninstallButton extends StatelessWidget {
  const _BulkUninstallButton({
    required this.count,
    required this.removing,
    this.onPressed,
  });

  final int count;
  final bool removing;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton.icon(
        // Disabled while a pass is in flight, so the control that started the
        // batch can't be used to start a second one over the same ids.
        onPressed: removing ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          disabledBackgroundColor: AppColors.accent.withValues(alpha: 0.5),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        icon: removing
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.delete_outline_rounded, size: 20),
        // Counts the selection, so the button states its own blast radius —
        // "Uninstall" alone on a screen of 160 rows is a claim about nothing.
        label: Text(
          removing
              ? context.l10n.removingSources
              : context.l10n.uninstallSelectedCount(count),
          style: AppText.body.copyWith(
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// One source row: name + status pill (Working / Slow / Dead-reason) with the
/// response time / result count, plus the removal control — a checkbox while
/// selecting, otherwise a per-row uninstall button.
class _HealthRow extends StatelessWidget {
  const _HealthRow({
    required this.result,
    required this.present,
    required this.searchIncluded,
    required this.selecting,
    required this.selected,
    this.onToggleSelected,
    this.onUninstall,
    this.playbackFails = 0,
  });

  final _ProbeResult result;
  final ({Color color, IconData icon, String label}) Function(SourceOutcome)
  present;
  final bool searchIncluded;

  /// Multi-select mode: show a checkbox and make the whole row the target,
  /// instead of a per-row action. 160 rows of individually-confirmed deletions
  /// is not a feature.
  final bool selecting;
  final bool selected;
  final VoidCallback? onToggleSelected;

  /// Removes THIS source, immediately, after its own confirmation. Null when the
  /// source has nothing installed behind it (Z-Mode), so no dead control.
  final VoidCallback? onUninstall;

  /// Distinct titles that recently failed to produce a playable link. This is
  /// the one thing the probe cannot see: a source whose search and episode
  /// lists are perfect, but whose embed host moved, so nothing plays.
  final int playbackFails;

  bool get _playbackDead => playbackFails >= SourceHealthStore.deadAfterTitles;

  String? get _meta {
    if (result.running) return null;
    // Real playback attempts outrank the probe: the probe only opens a title,
    // it never asks for a playable link.
    if (_playbackDead) {
      // Short on purpose: this shares one line with the status pill, and the
      // longer phrasing truncated to "No video from 6 recent ti…" on a phone.
      return 'No video · $playbackFails titles';
    }
    // The deep check answers the question the search probe can't ("can I
    // actually open anything?"), so when it ran it's the more useful line.
    final note = result.deepNote;
    if (note != null) return note;
    // No timing — response speed was misleading (context.l10n.slow sources are fine). Just
    // surface the result count when the source returned hits.
    final c = result.resultCount;
    if (c != null && c > 0) return '$c result${c == 1 ? '' : 's'}';
    return null;
  }

  bool get _isDead => result.outcome == SourceOutcome.error;

  @override
  Widget build(BuildContext context) {
    final o = result.outcome;
    var p = o == null ? null : present(o);
    // Searching fine but opening nothing is exactly the case a search-only
    // probe called context.l10n.working. Don't let the green tick stand.
    if (p != null && result.deepOk == false) {
      p = (
        color: const Color(0xFFE0A33A),
        icon: Icons.error_outline_rounded,
        label: context.l10n.notUsable,
      );
    } else if (p != null && result.deepOk == null && o == SourceOutcome.ok) {
      // Only the SEARCH probe has run — the deep check is opt-in behind the
      // microscope because it runs the JS engine on the UI isolate. So all this
      // green actually proves is that search answered. Saying "Working" claims
      // the source plays, which is precisely the thing it has not tested, and
      // is how a rotted source keeps a green tick. Stays green: search really
      // did work. Upgrades to the full label once the deep check has run.
      p = (color: p.color, icon: p.icon, label: context.l10n.searchOk);
    }

    final row = Padding(
      padding: EdgeInsets.fromLTRB(selecting ? 4 : 16, 12, 8, 12),
      child: Row(
        children: [
          if (selecting)
            Checkbox(
              value: selected,
              onChanged: (_) => onToggleSelected?.call(),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  result.name,
                  style: AppText.headline.copyWith(fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    if (result.running)
                      Text(context.l10n.testing, style: AppText.caption)
                    else if (p != null) ...[
                      Icon(p.icon, size: 14, color: p.color),
                      const SizedBox(width: 5),
                      Text(
                        p.label,
                        style: AppText.caption.copyWith(
                          color: p.color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (_meta != null) ...[
                        Text('  ·  ', style: AppText.caption),
                        Flexible(
                          child: Text(
                            _meta!,
                            style: AppText.caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
                if (!result.running && !searchIncluded) ...[
                  const SizedBox(height: 3),
                  Text(
                    context.l10n.notSearched,
                    style: AppText.overline.copyWith(
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (result.running)
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.accent,
              ),
            )
          else if (onUninstall != null)
            IconButton(
              onPressed: onUninstall,
              tooltip: context.l10n.uninstallSourceTooltip(result.name),
              icon: Icon(
                Icons.delete_outline_rounded,
                size: 20,
                // Tinted by state so the control reads as "this one, right now"
                // rather than a generic grey icon repeated down the list.
                color: (_isDead || _playbackDead)
                    ? AppColors.accent
                    : AppColors.textTertiary,
              ),
            ),
        ],
      ),
    );

    if (!selecting) return row;
    return InkWell(
      onTap: onToggleSelected,
      // The whole row is the checkbox target — a 24px checkbox is not a tap
      // target for "select these nine".
      child: row,
    );
  }
}
