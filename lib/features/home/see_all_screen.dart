import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/reveal_item.dart';
import 'see_all_screen_tv.dart';

/// Full-grid view of a single home row ("See All"). Reuses the home's tap /
/// long-press handlers so an item opens the same Detail / info card.
///
/// When [onLoadMore] is provided the grid paginates: scrolling near the bottom
/// fetches the next page and appends it (infinite scroll). When it's null the
/// grid is a fixed list over [items] — byte-for-byte the pre-pagination
/// behaviour, so search / JS / non-paginating callers are unchanged.
class SeeAllScreen extends StatefulWidget {
  const SeeAllScreen({
    super.key,
    required this.title,
    required this.items,
    required this.onTap,
    this.onLongPress,
    this.tagsFor,
    this.onLoadMore,
    this.onSearch,
  });

  final String title;
  final List<MediaItem> items;
  final void Function(MediaItem) onTap;
  final void Function(MediaItem)? onLongPress;

  /// Optional per-item poster badges (e.g. SUB/DUB/MOVIE). When null no tags are
  /// drawn — keeps the home "See All" callers unchanged.
  final List<String> Function(MediaItem)? tagsFor;

  /// Optional next-page fetcher for infinite scroll. `page` is 1-based and the
  /// initial [items] ARE page 1, so the first call requests page 2. Returning an
  /// empty list (or only already-seen items) ends pagination. Null → fixed list.
  final Future<List<MediaItem>> Function(int page)? onLoadMore;

  /// Optional search over the same source this row came from, which is what
  /// makes the search field worth having here at all.
  ///
  /// A home row is one slice of a catalogue — "Popular", "Action & Adventure",
  /// "Free Web Novel" — chosen by the provider, not by the reader. Somebody who
  /// arrived looking for one particular comic is on the wrong screen for it, and
  /// the only way out was back to the source's own search. `page` is 1-based and
  /// the first call is page 1, matching [onLoadMore] so results page the same way.
  ///
  /// Null hides the field entirely, which is what the non-source callers (search
  /// results, saved lists) pass.
  final Future<List<MediaItem>> Function(String query, int page)? onSearch;

  @override
  State<SeeAllScreen> createState() => _SeeAllScreenState();
}

class _SeeAllScreenState extends State<SeeAllScreen> {
  late final List<MediaItem> _items = [...widget.items];
  final Set<String> _seen = {};
  final ScrollController _controller = ScrollController();

  /// The last page already loaded — the initial [items] are page 1.
  int _page = 1;
  bool _loading = false;
  bool _end = false;

  // ── search ────────────────────────────────────────────────────────────────

  /// Is the search field open? Distinct from "a search is running": the field
  /// stays open (holding the query) across a search, so the reader can correct
  /// a typo without retyping the whole thing.
  bool _searchOpen = false;

  /// A request is in flight. The grid keeps showing what it had rather than
  /// blanking, because a spinner over an empty grid is a worse answer than the
  /// previous row while you type.
  bool _searching = false;

  /// The last search threw. Kept apart from "found nothing" — a source that
  /// failed is not a source with no results for that title.
  bool _searchFailed = false;

  /// Results behind [_query], or null while browsing the row. Null is the
  /// browsing state rather than an empty result, so exiting the search restores
  /// the row instead of restoring an empty grid.
  List<MediaItem>? _results;
  String _query = '';

  /// Paging state for the results, kept apart from the row's own [_page]/[_end]
  /// so leaving a search returns the row to exactly where it was.
  final Set<String> _resultSeen = {};
  int _resultPage = 1;
  bool _resultsEnd = false;

  /// Bumped per submitted search. A slow search whose answer arrives after a
  /// newer one has already landed would otherwise overwrite it, and the grid
  /// would show results for a query the reader has already replaced.
  int _searchToken = 0;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// What the grid is currently showing: search results if there are any, the
  /// row itself otherwise.
  List<MediaItem> get _visible => _results ?? _items;

  @override
  void initState() {
    super.initState();
    for (final it in _items) {
      _seen.add(_keyOf(it));
    }
    if (widget.onLoadMore != null || widget.onSearch != null) {
      _controller.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Dedupe key — prefer the stable id, fall back to the url.
  String _keyOf(MediaItem m) => m.id.isNotEmpty ? m.id : m.url;

  void _onScroll() {
    if (_loading || _end || !_controller.hasClients) return;
    final pos = _controller.position;
    if (pos.pixels >= pos.maxScrollExtent * 0.8) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loading) return;
    final inSearch = _results != null;
    if (inSearch ? _resultsEnd : _end) return;
    if (inSearch && widget.onSearch == null) return;
    if (!inSearch && widget.onLoadMore == null) return;
    if (!_controller.hasClients) return;
    setState(() => _loading = true);
    List<MediaItem> next = const [];
    try {
      next = inSearch
          ? await widget.onSearch!(_query, _resultPage + 1)
          : await widget.onLoadMore!(_page + 1);
    } catch (_) {
      next = const [];
    }
    if (!mounted) return;
    final seen = inSearch ? _resultSeen : _seen;
    final fresh = <MediaItem>[];
    for (final it in next) {
      final k = _keyOf(it);
      if (seen.add(k)) fresh.add(it);
    }
    setState(() {
      _loading = false;
      if (fresh.isEmpty) {
        // Nothing new (empty page or all duplicates) → we've hit the end.
        if (inSearch) {
          _resultsEnd = true;
        } else {
          _end = true;
        }
      } else if (inSearch) {
        _results!.addAll(fresh);
        _resultPage += 1;
      } else {
        _items.addAll(fresh);
        _page += 1;
      }
    });
  }

  void _openSearch() {
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  /// Closes the search and puts the row back exactly as it was.
  ///
  /// The results are dropped rather than kept behind a flag: a stale result set
  /// for a query the reader has walked away from is worse than the row they
  /// started from, and re-running the search is one tap away.
  void _closeSearch() {
    _searchToken++;
    _searchController.clear();
    _searchFocus.unfocus();
    setState(() {
      _searchOpen = false;
      _searching = false;
      _searchFailed = false;
      _results = null;
      _query = '';
      _resultSeen.clear();
      _resultPage = 1;
      _resultsEnd = false;
      _loading = false;
    });
  }

  Future<void> _submitSearch(String query) async {
    final search = widget.onSearch;
    if (search == null) return;
    final q = query.trim();
    if (q.isEmpty) {
      _closeSearch();
      return;
    }
    final token = ++_searchToken;
    setState(() {
      _searching = true;
      _searchFailed = false;
    });
    List<MediaItem> found = const [];
    var failed = false;
    try {
      found = await search(q, 1);
    } catch (_) {
      failed = true;
    }
    // A newer search was submitted while this one was in the air: that one owns
    // the screen now, and this answer is dropped rather than overwriting it.
    if (!mounted || token != _searchToken) return;
    setState(() {
      _searching = false;
      _searchFailed = failed;
      _query = q;
      _results = found;
      _resultSeen
        ..clear()
        ..addAll(found.map(_keyOf));
      _resultPage = 1;
      _resultsEnd = false;
      _loading = false;
    });
    // Results start at the top: the reader came here to read a title, not to
    // find themselves halfway down someone else's search.
    if (_controller.hasClients) _controller.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) {
      // The TV layout has no search field and no on-screen keyboard: a D-pad
      // search box is three inputs per character, and the source's own search
      // screen is one keypress away on the remote. Phone only, deliberately.
      return SeeAllScreenTv(
        title: widget.title,
        items: widget.items,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        tagsFor: widget.tagsFor,
        onLoadMore: widget.onLoadMore,
      );
    }
    final cellW = (MediaQuery.sizeOf(context).width - 32 - 24) / 3;
    // A trailing spinner cell spanning the full row while a page is loading.
    // Search results page too, so the spinner is not row-only any more.
    final showSpinner = _loading;
    final searching = _results != null;
    final empty = searching && !_searching && _results!.isEmpty;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: _searchOpen
            ? _searchField()
            : Text(widget.title, style: AppText.headline),
        // With the field open the back button means "leave the search", not
        // "leave the screen". Left as the route's own back button, the reader
        // who meant to correct a typo would instead lose the row they came from
        // — and the search would be the only thing they could not go back to.
        leading: _searchOpen
            ? IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: 'Back to the list',
                onPressed: _closeSearch,
              )
            : null,
        actions: _searchOpen
            ? null
            : [
                // Only when the caller can actually search. A See All over a
                // saved list or a set of search results has nothing to search,
                // and a field that searches nothing is worse than no field.
                if (widget.onSearch != null)
                  IconButton(
                    icon: const Icon(Icons.search_rounded),
                    tooltip: 'Search this source',
                    onPressed: _openSearch,
                  ),
              ],
      ),
      body: _searching
          ? const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : empty
          ? _emptyState()
          : GridView.builder(
              controller: _controller,
              padding: const EdgeInsets.all(16),
              cacheExtent: 800,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: posterGridAspect(context),
                crossAxisSpacing: 12,
                mainAxisSpacing: 16,
              ),
              itemCount: _visible.length,
              itemBuilder: (context, i) {
                final item = _visible[i];
                return RevealItem(
                  index: i,
                  child: PosterCard(
                    title: item.title,
                    imageUrl: item.cover,
                    headers: item.coverHeaders,
                    tags: widget.tagsFor?.call(item) ?? const [],
                    qualityBadge: item.quality,
                    scoreBadge: item.score,
                    dubBadge: item.dubBadge,
                    cellWidth: cellW,
                    onTap: () => widget.onTap(item),
                    onLongPress: widget.onLongPress == null
                        ? null
                        : () => widget.onLongPress!(item),
                  ),
                );
              },
            ),
      // Bottom loading indicator while the next page is in flight.
      bottomNavigationBar: showSpinner
          ? const SizedBox(
              height: 48,
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : null,
    );
  }

  /// The search field, which replaces the row's title rather than sitting above
  /// the grid: on a phone the grid starts 16px under the app bar, and a second
  /// row of controls there costs a whole screenful of covers on a device that
  /// already only fits three across.
  Widget _searchField() => TextField(
    controller: _searchController,
    focusNode: _searchFocus,
    autofocus: true,
    textInputAction: TextInputAction.search,
    style: AppText.headline,
    cursorColor: AppColors.accent,
    onSubmitted: _submitSearch,
    decoration: InputDecoration(
      hintText: 'Search this source',
      border: InputBorder.none,
      isDense: true,
      suffixIcon: _searchController.text.isEmpty
          ? null
          : IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              tooltip: 'Clear',
              onPressed: () => setState(_searchController.clear),
            ),
    ),
    onChanged: (_) => setState(() {}),
  );

  /// Says which of the two "nothing here" cases this is.
  ///
  /// A source that failed and a source with no match for the title look
  /// identical on screen otherwise, and they need opposite responses: retry vs
  /// try another title.
  Widget _emptyState() => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _searchFailed
                ? Icons.cloud_off_rounded
                : Icons.search_off_rounded,
            color: AppColors.textSecondary,
            size: 34,
          ),
          const SizedBox(height: 12),
          Text(
            _searchFailed
                ? 'This source could not be searched. Try again in a moment.'
                : 'Nothing here for "$_query".',
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    ),
  );
}
