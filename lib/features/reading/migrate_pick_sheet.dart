import 'package:flutter/material.dart';

import '../../core/models/media_item.dart';
import '../../core/reading/novel_migrator.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

/// Picks the source a novel should move to.
///
/// Shared by both migration entry points - the per-book picker and the
/// per-source sweep - because the decision they are asking the reader to make is
/// identical, and a reader who learned it in one place should not meet a
/// different sheet in the other.
///
/// ## Why this asks instead of choosing
///
/// Two sites carrying the same title are two different books: different
/// translations, different chapter counts, sometimes different authors. Only the
/// reader knows which one they were reading. So this lists what each source
/// offered, best match first, and waits.
///
/// Sources that did not answer are shown as such rather than dropped, because
/// "Chikari had nothing" and "Chikari is broken" call for different reactions -
/// one is fine, the other is why this screen exists.
class MigratePickSheet extends StatefulWidget {
  const MigratePickSheet({
    super.key,
    required this.title,
    required this.search,
    this.excludeSourceId,
    this.sourceIds,
  });

  /// The novel being moved, named in the sheet's header.
  final String title;

  /// Runs the search. Injected so the sheet does not reach for DI itself and
  /// can be driven by a test with a fixed candidate list.
  final Future<List<MigrationCandidate>> Function(String title) search;

  /// The source the novel is on now, listed but not selectable - moving a book
  /// to the source it is already on is not a migration.
  final String? excludeSourceId;

  /// Restricts which sources are asked, for the per-source sweep.
  final List<String>? sourceIds;

  /// Opens the sheet and returns the chosen candidate, or null if dismissed.
  static Future<MediaItem?> show(
    BuildContext context, {
    required String title,
    required Future<List<MigrationCandidate>> Function(String title) search,
    String? excludeSourceId,
    List<String>? sourceIds,
  }) => showModalBottomSheet<MediaItem>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    barrierColor: Colors.black54,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => MigratePickSheet(
      title: title,
      search: search,
      excludeSourceId: excludeSourceId,
      sourceIds: sourceIds,
    ),
  );

  @override
  State<MigratePickSheet> createState() => _MigratePickSheetState();
}

class _MigratePickSheetState extends State<MigratePickSheet> {
  late Future<List<MigrationCandidate>> _future;
  bool _searchingAgain = false;

  @override
  void initState() {
    super.initState();
    _future = widget.search(widget.title);
  }

  void _retry() {
    setState(() {
      _searchingAgain = true;
      _future = widget.search(widget.title);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FractionallySizedBox(
        // Tall enough to show a useful number of candidates without the reader
        // having to drag, short enough that the novel's own title stays
        // visible behind it.
        heightFactor: 0.78,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Move to another source', style: AppText.headline),
                        const SizedBox(height: 2),
                        Text(
                          widget.title,
                          style: AppText.caption,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Search again',
                    icon: const Icon(Icons.refresh_rounded),
                    color: AppColors.textSecondary,
                    onPressed: _searchingAgain ? null : _retry,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'The same title on two sites is two different book. Pick the one '
                'you were reading.',
                style: AppText.overline.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<MigrationCandidate>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        // Not const: AppColors.accent is a runtime-mutable
                        // static so it can be themed.
                        child: CircularProgressIndicator(
                          color: AppColors.accent,
                        ),
                      ),
                    );
                  }
                  if (snap.hasError) {
                    return _Message(
                      icon: Icons.cloud_off_rounded,
                      text: 'Could not search your sources.',
                      onRetry: _retry,
                    );
                  }
                  final all = snap.data ?? const <MigrationCandidate>[];
                  // The current source is not offered: it is where the book
                  // already is, and tapping it would strand the reader's own
                  // reading position under a key they never left.
                  final rows = [
                    for (final c in all)
                      if (c.sourceId != widget.excludeSourceId) c,
                  ];
                  final selectable = rows.where((c) => !c.failed).toList();
                  // Sources that did not answer. Kept apart from "had nothing"
                  // and shown at the foot of the list rather than mixed in:
                  // a source that answered with no results is fine, and one
                  // that was blocked is the reason this screen exists. Silently
                  // dropping them made a broken source indistinguishable from
                  // one that simply does not carry this title.
                  final failed = rows.where((c) => c.failed).toList();
                  if (selectable.isEmpty && failed.isEmpty) {
                    return _Message(
                      icon: Icons.search_off_rounded,
                      text: 'No installed source has "${widget.title}".',
                      onRetry: _retry,
                    );
                  }
                  if (selectable.isEmpty) {
                    return _Message(
                      icon: Icons.cloud_off_rounded,
                      text:
                          'None of your ${failed.length} sources answered. They '
                          'may all be blocked - try again later.',
                      onRetry: _retry,
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                    itemCount: selectable.length + (failed.isEmpty ? 0 : 1),
                    separatorBuilder: (_, _) => const SizedBox(height: 2),
                    itemBuilder: (context, i) {
                      if (i >= selectable.length) {
                        return _FailedSources(failed: failed);
                      }
                      final c = selectable[i];
                      return _CandidateRow(
                        candidate: c,
                        onTap: () => Navigator.of(context).pop(c.item),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CandidateRow extends StatelessWidget {
  const _CandidateRow({required this.candidate, required this.onTap});

  final MigrationCandidate candidate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final item = candidate.item!;
    // Score is a ranking signal, not a claim of correctness - "exact match" is
    // honest, "93% match" is not, and a percentage here would read as a promise
    // the ranking cannot keep.
    final exact = candidate.score == 100;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: [
            _Thumb(url: item.cover),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: AppText.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          item.sourceId,
                          style: AppText.overline.copyWith(
                            color: AppColors.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (exact) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.check_circle_rounded,
                          size: 13,
                          color: AppColors.accent,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

/// The sources that did not answer, named.
///
/// Not selectable and not a result - this is the "you should probably fix this"
/// footer. Naming them is the point: a reader who is told "12 sources did not
/// answer" learns nothing, and one told which can go check whether the site is
/// down or their own connection is.
class _FailedSources extends StatelessWidget {
  const _FailedSources({required this.failed});

  final List<MigrationCandidate> failed;

  @override
  Widget build(BuildContext context) {
    final names = [for (final c in failed) c.sourceId ?? '?'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 14,
                color: AppColors.textTertiary,
              ),
              const SizedBox(width: 6),
              Text(
                '${names.length} source${names.length == 1 ? '' : 's'} did not '
                'answer',
                style: AppText.overline.copyWith(
                  color: AppColors.textTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            names.join(', '),
            style: AppText.overline.copyWith(
              color: AppColors.textTertiary.withValues(alpha: 0.8),
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 40,
        height: 56,
        child: url == null
            ? Container(color: AppColors.surface)
            : Image.network(
                url!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Container(color: AppColors.surface),
              ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    this.onRetry,
  });

  final IconData icon;
  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.textSecondary),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}