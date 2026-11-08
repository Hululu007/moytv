import 'dart:async';

import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'models.dart';

class HongguoComment {
  const HongguoComment({
    required this.id,
    required this.text,
    required this.userName,
    required this.avatar,
    required this.timeSec,
  });

  final String id;
  final String text;
  final String userName;
  final String avatar;
  final int timeSec;

  factory HongguoComment.fromJson(Map<String, dynamic> json) {
    return HongguoComment(
      id: json['id'] as String? ?? '',
      text: json['text'] as String? ?? '',
      userName: json['userName'] as String? ?? '',
      avatar: json['avatar'] as String? ?? '',
      timeSec: intValue(json['timeSec']),
    );
  }
}

class HongguoCommentPage {
  const HongguoCommentPage({
    required this.items,
    required this.cursor,
    required this.hasMore,
    required this.total,
    required this.collectorsCount,
    required this.score,
    required this.scoreCount,
  });

  final List<HongguoComment> items;
  final String cursor;
  final bool hasMore;
  final int total;
  final int collectorsCount;
  final double score;
  final int scoreCount;

  factory HongguoCommentPage.fromJson(Map<String, dynamic> json) {
    return HongguoCommentPage(
      items: [
        for (final row in json['items'] as List? ?? const [])
          if (row is Map<String, dynamic>) HongguoComment.fromJson(row),
      ],
      cursor: json['cursor'] as String? ?? '',
      hasMore: json['hasMore'] as bool? ?? false,
      total: intValue(json['total']),
      collectorsCount: intValue(json['collectorsCount']),
      score: (json['score'] as num?)?.toDouble() ?? 0,
      scoreCount: intValue(json['scoreCount']),
    );
  }

  static const empty = HongguoCommentPage(
    items: [],
    cursor: '',
    hasMore: false,
    total: 0,
    collectorsCount: 0,
    score: 0,
    scoreCount: 0,
  );
}

String hongguoCommentTime(int timeSec) {
  if (timeSec <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(timeSec * 1000);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

class HongguoCommentSheet extends StatefulWidget {
  const HongguoCommentSheet({
    super.key,
    required this.plan,
    required this.repository,
    this.initialPage,
    this.seriesId,
  });

  final PlaybackPlan plan;
  final AppRepository repository;
  final HongguoCommentPage? initialPage;
  final String? seriesId;

  @override
  State<HongguoCommentSheet> createState() => _HongguoCommentSheetState();
}

class _HongguoCommentSheetState extends State<HongguoCommentSheet> {
  late List<HongguoComment> _items;
  late String _cursor;
  late bool _hasMore;
  late int _total;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialPage;
    _items = initial?.items ?? [];
    _cursor = initial?.cursor ?? '';
    _hasMore = initial?.hasMore ?? false;
    _total = initial?.total ?? 0;
    if (initial == null) unawaited(_loadFirst());
  }

  Future<void> _loadFirst() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _fetchComments();
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _total = page.total;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() {
      _loadingMore = true;
      _error = null;
    });
    try {
      final page = await _fetchComments(cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...page.items];
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        if (page.total > 0) _total = page.total;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loadingMore = false;
      });
    }
  }

  Future<HongguoCommentPage> _fetchComments({String cursor = ''}) {
    final seriesId = widget.seriesId;
    if (seriesId != null) {
      return widget.repository.commentsBySeries(seriesId, cursor: cursor);
    }
    return widget.repository.comments(widget.plan, cursor: cursor);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _total > 0 ? '评论 · $_total条' : '评论',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null && _items.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _loadFirst,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  )
                : _items.isEmpty
                ? const Center(child: Text('暂无评论'))
                : ListView.builder(
                    itemCount: _items.length + 1,
                    itemBuilder: (context, index) {
                      if (index >= _items.length) {
                        if (!_hasMore) return const SizedBox(height: 16);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Center(
                            child: _loadingMore
                                ? const CircularProgressIndicator()
                                : _error != null
                                ? TextButton(
                                    onPressed: _loadMore,
                                    child: const Text('加载失败，点此重试'),
                                  )
                                : TextButton(
                                    onPressed: _loadMore,
                                    child: const Text('加载更多'),
                                  ),
                          ),
                        );
                      }
                      final comment = _items[index];
                      return ListTile(
                        leading: comment.avatar.isEmpty
                            ? const CircleAvatar(child: Icon(Icons.person))
                            : CircleAvatar(
                                backgroundImage: NetworkImage(comment.avatar),
                                onBackgroundImageError: (_, _) {},
                              ),
                        title: Text(
                          comment.userName.isEmpty ? '匿名用户' : comment.userName,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(comment.text),
                            if (comment.timeSec > 0)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  hongguoCommentTime(comment.timeSec),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                          ],
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

Future<HongguoCommentPage?> showHongguoComments(
  BuildContext context,
  PlaybackPlan plan,
  AppRepository repository, {
  HongguoCommentPage? initialPage,
  String? seriesId,
}) {
  return showModalBottomSheet<HongguoCommentPage>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => SizedBox(
      height: MediaQuery.of(context).size.height * 0.78,
      child: HongguoCommentSheet(
        plan: plan,
        repository: repository,
        initialPage: initialPage,
        seriesId: seriesId,
      ),
    ),
  );
}
