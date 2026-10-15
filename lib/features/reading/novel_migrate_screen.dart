import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart' show ProviderType;
import '../../core/playback/my_list.dart';
import '../../core/reading/read_history.dart' show ReadHistory;
import '../../core/reading/novel_migrator.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';
import 'migrate_pick_sheet.dart';

/// Lists every novel in My List with a way to move it to another source.
///
/// This is the per-book half of migration. The per-source sweep lives in
/// [SourceMigrateScreen]; this one answers "this one book came from a source
/// that went away", which is the common case - an extension breaks, not a whole
/// catalogue.
///
/// ## Why it lists rather than migrates
///
/// Migrating is re-pointing saved data, and which source a reader actually
/// wanted is not derivable - the same title on two sites is two different
/// translation. So this screen collects the decisions and reports them; the only
/// thing that writes is [NovelMigrator.migrate], behind a confirmation naming
/// what will move.
class NovelMigrateScreen extends StatefulWidget {
  const NovelMigrateScreen({super.key});

  @override
  State<NovelMigrateScreen> createState() => _NovelMigrateScreenState();
}

class _NovelMigrateScreenState extends State<NovelMigrateScreen> {
  late final MyListStore _list;
  late final NovelMigrator _migrator;

  /// Original entry -> chosen replacement, applied when Apply is pressed.
  final Map<MediaItem, MediaItem> _picked = {};

  bool _loading = true;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _list = sl<MyListStore>();
    _migrator = sl<NovelMigrator>();
    _load();
  }

  Future<void> _load() async {
    final novels = _list
        .all()
        .where((m) => m.type == ProviderType.novel)
        .toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    if (!mounted) return;
    setState(() {
      _books = novels;
      _loading = false;
    });
  }

  List<MediaItem> _books = const [];

  Future<void> _choose(MediaItem book) async {
    final picked = await MigratePickSheet.show(
      context,
      title: book.title,
      excludeSourceId: book.sourceId,
      search: (t) => _migrator.matchCandidates(t),
    );
    if (picked == null || !mounted) return;
    setState(() => _picked[book] = picked);
  }

  Future<void> _applyAll() async {
    if (_picked.isEmpty || _applying) return;
    final entries = _picked.entries.toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          entries.length == 1
              ? 'Move 1 novel?'
              : 'Move ${entries.length} novels?',
        ),
        content: Text(
          'They will be re-pointed at the sources you picked, and your reading '
          'position will carry over where the new source has that chapter.\n\n'
          'Nothing is deleted from the old sources.',
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
    if (confirmed != true || !mounted) return;

    setState(() => _applying = true);
    var moved = 0;
    var carried = 0;
    for (final e in entries) {
      try {
        final furthest = _furthestRead(e.key);
        final res = await _migrator.migrate(
          from: e.key,
          to: e.value,
          chapterNumber: furthest?.number,
          chapterId: furthest?.chapterId,
        );
        if (res.ok) {
          moved++;
          if (res.carriedPosition) carried++;
        }
      } catch (_) {
        // One stubborn book must not strand the rest of the batch.
      }
    }
    if (!mounted) return;
    setState(() {
      _picked.clear();
      _applying = false;
    });
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            moved == 0
                ? 'Nothing moved.'
                : 'Moved $moved'
                      '${carried > 0 ? ', $carried resumed where you left off' : ''}.',
          ),
        ),
      );
  }

  /// The chapter the reader had reached on this book, as a number and the id it
  /// had there.
  ///
  /// Null when they never opened it, in which case there is nothing to carry and
  /// the book simply opens at chapter one on the new source.
  ///
  /// Read history is keyed one row per title, so this is that row - not a scan
  /// for the highest chapter across many. The two halves have to describe the
  /// same chapter: the number is what the destination's chapter list is searched
  /// for, and the id is what selects the stored position that travels with it.
  ({int number, String chapterId})? _furthestRead(MediaItem book) {
    final e = sl<ReadHistory>().get(book.sourceId, book.id);
    final n = e?.chapterNumber;
    if (e == null || n == null) return null;
    return (number: n.round(), chapterId: e.chapterId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(
        'Migrate novels',
        actions: [
          if (_picked.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton(
                onPressed: _applying ? null : _applyAll,
                child: Text('Move ${_picked.length}'),
              ),
            ),
        ],
      ),
      body: _body(),
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
                        : 'Move ${_picked.length} novel'
                              '${_picked.length == 1 ? '' : 's'}',
                  ),
                ),
              ),
            ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (_books.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'No novels in My List yet. Add one and it will show up here.',
            textAlign: TextAlign.center,
            style: AppText.caption.copyWith(color: AppColors.textSecondary),
          ),
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
                ? book.sourceId
                // Naming BOTH ends is the point: the reader has to be able to
                // see they picked the one they meant before anything is written.
                : '${book.sourceId} → ${target.sourceId}',
            style: AppText.overline.copyWith(
              color: target == null ? AppColors.textSecondary : AppColors.accent,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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