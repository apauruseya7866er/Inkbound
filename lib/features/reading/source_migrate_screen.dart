import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart' show ProviderType;
import '../../core/playback/my_list.dart';
import '../../core/reading/novel_migrator.dart';
import '../../core/reading/read_history.dart' show ReadHistory;
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';
import 'migrate_pick_sheet.dart';

/// Moves every novel on one source to another, in bulk.
///
/// The per-source half of migration. Where [NovelMigrateScreen] answers "this
/// one book came from a source that went away", this answers "this whole source
/// is gone" - which is what happens when an extension breaks or the site shuts
/// down, and which leaves a reader with a library full of books that cannot be
/// opened.
///
/// ## Why the source is chosen first
///
/// Searching forty sources per book, for forty books, is 1,600 requests and a
/// very long screen. The reader already knows which source is broken, so this
/// narrows the search space once and asks about the rest. It also makes the
/// batch coherent: every book ends up somewhere deliberate rather than wherever
/// a sweep happened to rank it.
///
/// ## What it does with the books it cannot place
///
/// Nothing. A book whose title is not found is left where it is and reported by
/// name, because silently dropping it from a batch looks like the book was
/// deleted. The old entries are never removed.
class SourceMigrateScreen extends StatefulWidget {
  const SourceMigrateScreen({super.key, this.presetSourceId});

  /// Opens with one source already chosen, for the "migrate away from this"
  /// route where the reader already tapped a dead source.
  final String? presetSourceId;

  @override
  State<SourceMigrateScreen> createState() => _SourceMigrateScreenState();
}

class _SourceMigrateScreenState extends State<SourceMigrateScreen> {
  late final MyListStore _list;
  late final SourceRepository _sources;
  late final NovelMigrator _migrator;

  String? _fromSourceId;
  List<MediaItem> _books = const [];
  final Map<MediaItem, MediaItem> _picked = {};
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _list = sl<MyListStore>();
    _sources = sl<SourceRepository>();
    _migrator = sl<NovelMigrator>();
    if (widget.presetSourceId != null) {
      _fromSourceId = widget.presetSourceId;
      _loadBooks();
    }
  }

  /// Sources that currently hold at least one saved novel, with a count.
  ///
  /// Counting up front is what makes this screen usable: "Novel Fire (14)" says
  /// the sweep is worth starting, and a source with nothing on it does not
  /// appear at all rather than leading to an empty result screen.
  List<({String id, String name, int count})> get _sourcesWithBooks {
    final counts = <String, int>{};
    final names = <String, String>{};
    for (final m in _list.all()) {
      if (m.type != ProviderType.novel) continue;
      counts[m.sourceId] = (counts[m.sourceId] ?? 0) + 1;
      names[m.sourceId] ??= m.sourceId;
    }
    final rows = [
      for (final e in counts.entries)
        (id: e.key, name: names[e.key]!, count: e.value),
    ];
    rows.sort((a, b) => b.count.compareTo(a.count));
    return rows;
  }

  void _loadBooks() {
    final id = _fromSourceId;
    if (id == null) return;
    final books = _list
        .all()
        .where((m) => m.type == ProviderType.novel && m.sourceId == id)
        .toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    setState(() {
      _books = books;
      _picked.clear();
    });
  }

  Future<void> _choose(MediaItem book) async {
    final from = _fromSourceId;
    if (from == null) return;
    final picked = await MigratePickSheet.show(
      context,
      title: book.title,
      excludeSourceId: from,
      // Only the OTHER sources are candidates: the book is on the source being
      // migrated away from, and asking it again produces the book itself.
      sourceIds: [
        for (final id in _sources.loadedSources.map((s) => s.id))
          if (id != from) id,
      ],
      search: (t) => _migrator.matchCandidates(
        t,
        sourceIds: [
          for (final id in _sources.loadedSources.map((s) => s.id))
            if (id != from) id,
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _picked[book] = picked);
  }

  int? _chapterOf(MediaItem book) {
    final nums = sl<ReadHistory>()
        .all()
        .where((e) => e.sourceId == book.sourceId && e.showId == book.id)
        .map((e) => e.chapterNumber)
        .whereType<num>()
        .map((n) => n.round())
        .toList();
    if (nums.isEmpty) return null;
    return nums.reduce((a, b) => a > b ? a : b);
  }

  Future<void> _applyAll() async {
    if (_picked.isEmpty || _applying) return;
    final entries = _picked.entries.toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Move ${entries.length} novel${entries.length == 1 ? '' : 's'}?'),
        content: const Text(
          'They will be re-pointed at the sources you picked, and your reading '
          'position will carry over where the new source has that chapter.\n\n'
          'Nothing is deleted from the old source.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Move'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _applying = true);
    var moved = 0;
    for (final e in entries) {
      try {
        final res = await _migrator.migrate(
          from: e.key,
          to: e.value,
          chapterNumber: _chapterOf(e.key),
        );
        // A refused book is simply still on the source afterwards, so it is
        // covered by the "still on this source" count below. Counting it twice
        // would make the summary contradict itself.
        if (res.ok) moved++;
      } catch (_) {
        // Same: it stays where it was, and the summary says so.
      }
    }
    final total = _books.length;
    if (!mounted) return;
    setState(() {
      _picked.clear();
      _applying = false;
    });
    _loadBooks();
    if (!mounted) return;
    // The unplaced ones are NAMED. A batch that quietly drops books reads as
    // data loss, and the reader has no other way to know which are still stuck.
    final stuck = _books.length;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            moved == 0
                ? 'Nothing moved.'
                : 'Moved $moved of $total'
                      '${stuck > 0 ? '. $stuck still on this source' : ''}.',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final from = _fromSourceId;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(
        from == null ? 'Migrate a source' : 'Move away from $from',
        actions: [
          if (from != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: TextButton(
                onPressed: () => setState(() {
                  _fromSourceId = null;
                  _books = const [];
                }),
                child: const Text('Change'),
              ),
            ),
        ],
      ),
      body: from == null ? _sourceList() : _bookList(),
      bottomNavigationBar: _picked.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton(
                  onPressed: _applying ? null : _applyAll,
                  child: Text(
                    _applying
                        ? 'Moving…'
                        : 'Move ${_picked.length} of ${_books.length}',
                  ),
                ),
              ),
            ),
    );
  }

  Widget _sourceList() {
    final rows = _sourcesWithBooks;
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'No novels in My List to migrate.',
            textAlign: TextAlign.center,
            style: AppText.caption.copyWith(color: AppColors.textSecondary),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const Divider(height: 0.5, color: AppColors.hairline),
      itemBuilder: (context, i) {
        final r = rows[i];
        return ListTile(
          leading: const Icon(Icons.library_books_outlined),
          title: Text(r.id, style: AppText.body),
          // The count decides whether this is worth tapping, so it leads.
          subtitle: Text(
            '${r.count} novel${r.count == 1 ? '' : 's'}',
            style: AppText.overline.copyWith(color: AppColors.textSecondary),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () {
            setState(() => _fromSourceId = r.id);
            _loadBooks();
          },
        );
      },
    );
  }

  Widget _bookList() {
    if (_books.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: CircularProgressIndicator(color: AppColors.accent),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: _books.length,
      separatorBuilder: (_, _) => const Divider(height: 0.5, color: AppColors.hairline),
      itemBuilder: (context, i) {
        final book = _books[i];
        final target = _picked[book];
        return ListTile(
          leading: SizedBox(
            width: 40,
            height: 56,
            child: book.cover == null
                ? const SizedBox.shrink()
                : Image.network(
                    book.cover!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
          ),
          title: Text(
            book.title,
            style: AppText.body,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            target == null
                ? 'Tap to choose a new source'
                : '→ ${target.sourceId}',
            style: AppText.overline.copyWith(
              color: target == null
                  ? AppColors.textSecondary
                  : AppColors.accent,
            ),
          ),
          trailing: target == null
              ? const Icon(Icons.swap_horiz_rounded, color: AppColors.textSecondary)
              : IconButton(
                  tooltip: 'Change',
                  icon: const Icon(Icons.close_rounded, size: 20),
                  color: AppColors.textTertiary,
                  onPressed: () => setState(() => _picked.remove(book)),
                ),
          onTap: () => _choose(book),
        );
      },
    );
  }
}