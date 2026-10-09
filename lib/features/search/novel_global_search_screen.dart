import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/models/media_item.dart';
import '../../core/theme/app_colors.dart';
import '../detail/detail_screen.dart';
import 'novel_global_search_cubit.dart';

/// Search every installed novel source for one title.
///
/// Separate from the general search screen on purpose. That one answers "what
/// can I find on the source I am looking at", and its scope follows whatever
/// mode Home is in - which means a reader who wants to know which of their
/// sources carries a book cannot get an answer from it without first changing
/// mode, and often cannot get it at all. This one is pinned to novels.
///
/// The general Home search is untouched and still does its own job.
class NovelGlobalSearchScreen extends StatelessWidget {
  const NovelGlobalSearchScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => NovelGlobalSearchCubit(),
      child: const _NovelGlobalSearchView(),
    );
  }
}

class _NovelGlobalSearchView extends StatefulWidget {
  const _NovelGlobalSearchView();

  @override
  State<_NovelGlobalSearchView> createState() => _NovelGlobalSearchViewState();
}

class _NovelGlobalSearchViewState extends State<_NovelGlobalSearchView> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<NovelGlobalSearchCubit>();
    return Scaffold(
      appBar: AppBar(title: const Text('Search novels')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                textInputAction: TextInputAction.search,
                onChanged: cubit.queryChanged,
                onSubmitted: cubit.search,
                decoration: InputDecoration(
                  hintText: 'Search every novel source',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _controller.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () {
                            _controller.clear();
                            cubit.search('');
                          },
                        ),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const _ScopeFilters(),
            Expanded(
              child: BlocBuilder<NovelGlobalSearchCubit, NovelGlobalSearchState>(
                builder: (context, state) => _Body(state: state, cubit: cubit),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// All / Pinned / Has results.
///
/// Not decoration: "all of them" and "the ones I chose" are different questions
/// with different answers, and hiding the second is how a long list of sources
/// becomes unreadable.
class _ScopeFilters extends StatelessWidget {
  const _ScopeFilters();

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<NovelGlobalSearchCubit>();
    return BlocBuilder<NovelGlobalSearchCubit, NovelGlobalSearchState>(
      buildWhen: (a, b) =>
          a.pinnedOnly != b.pinnedOnly || a.hideEmpty != b.hideEmpty,
      builder: (context, state) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            _Chip(
              label: 'All',
              selected: !state.pinnedOnly,
              onTap: () => cubit.setPinnedOnly(false),
            ),
            const SizedBox(width: 8),
            _Chip(
              label: 'Pinned',
              selected: state.pinnedOnly,
              onTap: () => cubit.setPinnedOnly(true),
            ),
            const SizedBox(width: 8),
            _Chip(
              label: 'Has results',
              selected: state.hideEmpty,
              onTap: () => cubit.setHideEmpty(!state.hideEmpty),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ChoiceChip(
    label: Text(label),
    selected: selected,
    onSelected: (_) => onTap(),
    visualDensity: VisualDensity.compact,
  );
}

class _Body extends StatelessWidget {
  const _Body({required this.state, required this.cubit});

  final NovelGlobalSearchState state;
  final NovelGlobalSearchCubit cubit;

  @override
  Widget build(BuildContext context) {
    if (state.query.isEmpty) {
      return const _Message(
        icon: Icons.menu_book_rounded,
        text: 'Type a title to search every novel source you have.',
      );
    }
    if (state.noSources) {
      return const _Message(
        icon: Icons.search_off_rounded,
        text: 'No novel sources are switched on for search.',
      );
    }
    final groups = cubit.visibleGroups();
    if (groups.isEmpty) {
      return const _Message(
        icon: Icons.search_off_rounded,
        text: 'Nothing matched.',
      );
    }
    return ListView.builder(
      // One extra row for the "nothing anywhere" line, so a settled search that
      // found nothing says so rather than showing an empty screen.
      itemCount: groups.length + (state.allEmpty ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= groups.length) {
          return const _Message(
            icon: Icons.search_off_rounded,
            text: 'None of your novel sources had this title.',
          );
        }
        return _SourceSection(group: groups[i]);
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Center(
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
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ],
      ),
    ),
  );
}

/// One source, named, with its own results.
class _SourceSection extends StatelessWidget {
  const _SourceSection({required this.group});

  final NovelSourceGroup group;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                // The source name is what makes a row trustworthy: the same
                // title on two sites is two different books.
                Text(
                  group.sourceName,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                _StatusLabel(status: group.status),
              ],
            ),
          ),
          SizedBox(
            height: 208,
            child: switch (group.status) {
              NovelSourceStatus.loading => const _SectionSkeleton(),
              NovelSourceStatus.hits => _NovelRow(group: group),
              NovelSourceStatus.empty || NovelSourceStatus.failed =>
                const SizedBox.shrink(),
            },
          ),
        ],
      ),
    );
  }
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.status});

  final NovelSourceStatus status;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (status) {
      NovelSourceStatus.loading => ('Searching…', AppColors.textSecondary),
      NovelSourceStatus.hits => ('', AppColors.textSecondary),
      NovelSourceStatus.empty => ('No matches', AppColors.textSecondary),
      NovelSourceStatus.failed => ("Couldn't reach", AppColors.accent),
    };
    if (text.isEmpty) return const SizedBox.shrink();
    return Text(
      text,
      style: TextStyle(fontSize: 12, color: color),
    );
  }
}

/// The horizontal novel cards.
class _NovelRow extends StatelessWidget {
  const _NovelRow({required this.group});

  final NovelSourceGroup group;

  @override
  Widget build(BuildContext context) => ListView.separated(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    itemCount: group.items.length,
    separatorBuilder: (_, _) => const SizedBox(width: 12),
    itemBuilder: (context, i) => _NovelCard(
      item: group.items[i],
      source: group.sourceName,
    ),
  );
}

class _NovelCard extends StatelessWidget {
  const _NovelCard({required this.item, required this.source});

  final MediaItem item;

  /// Which source this copy came from. Not used for routing -
  /// [DetailScreen.route] carries the item, whose own `sourceId` is the one the
  /// search was made against - but kept so a card can never be built without
  /// its row's context. Routing by "whatever source is active now" is how a tap
  /// ends up on the wrong site's copy of a book.
  final String source;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 124,
      child: InkWell(
        key: ValueKey('novel-search-card-${item.id}'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => Navigator.of(context).push(DetailScreen.route(item)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: (item.cover ?? '').isEmpty
                    ? Container(color: AppColors.surface2)
                    : Image.network(
                        item.cover!,
                        fit: BoxFit.cover,
                        // A cover that will not load is not a reason to lose the
                        // result - the title is what the reader is after.
                        errorBuilder: (_, _, _) =>
                            Container(color: AppColors.surface2),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionSkeleton extends StatelessWidget {
  const _SectionSkeleton();

  @override
  Widget build(BuildContext context) => ListView.separated(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    itemCount: 4,
    separatorBuilder: (_, _) => const SizedBox(width: 12),
    itemBuilder: (_, _) => Container(
      width: 124,
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(10),
      ),
    ),
  );
}