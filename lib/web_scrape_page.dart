import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'py_spider_generator.dart';
import 'web_scrape_analyzer.dart';

/// 网页爬取页：输入网址，真实抓取并展示本次爬到的实际数据；数据齐全时
/// 可一键生成 TVBox Python 蜘蛛并导出。验证页/盾/登录墙一律诚实报错，
/// 绝不绕过。生成的蜘蛛默认不注册进站点列表，只保存或复制给用户。
class WebScrapePage extends StatefulWidget {
  const WebScrapePage({super.key});

  @override
  State<WebScrapePage> createState() => _WebScrapePageState();
}

class _WebScrapePageState extends State<WebScrapePage> {
  final TextEditingController _url = TextEditingController();
  final WebScrapeAnalyzer _analyzer = WebScrapeAnalyzer();
  bool _busy = false;
  String? _error;
  ScrapedSiteData? _data;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _data = null;
    });
    try {
      final data = await _analyzer.analyze(_url.text);
      if (!mounted) return;
      setState(() => _data = data);
    } on ScrapeFailure catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '爬取失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _generate() {
    final data = _data;
    if (data == null) return;
    GeneratedPySpider generated;
    try {
      generated = generatePySpider(data);
    } on PyGeneratorException catch (e) {
      _showMessage('数据不足，无法生成：${e.reasons.first}');
      return;
    }
    _showCodeDialog(generated);
  }

  void _showCodeDialog(GeneratedPySpider generated) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(generated.fileName),
        content: SizedBox(
          width: double.maxFinite,
          height: 320,
          child: SingleChildScrollView(
            child: SelectableText(
              generated.source,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: generated.source));
              if (!mounted) return;
              _showMessage('已复制到剪贴板');
            },
            child: const Text('复制全文'),
          ),
          TextButton(
            onPressed: () async {
              final saved = await FilePicker.saveFile(
                fileName: generated.fileName,
                bytes: Uint8List.fromList(utf8.encode(generated.source)),
                mimeType: 'text/x-python',
              );
              if (!mounted) return;
              if (saved != null) {
                _showMessage('已保存到 $saved');
              }
            },
            child: const Text('保存文件'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = _data;
    final blockers = data == null ? null : generationBlockers(data);
    return Scaffold(
      appBar: AppBar(title: const Text('网页爬取')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('web-scrape-url-input'),
              controller: _url,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _run(),
              decoration: const InputDecoration(
                labelText: '站点首页网址',
                hintText: 'https://example.com/',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '只抓取公开页面；遇到验证页、登录墙会如实报错，不会绕过。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('web-scrape-run'),
              onPressed: _busy ? null : _run,
              icon: const Icon(Icons.travel_explore_rounded),
              label: const Text('开始爬取'),
            ),
            if (_busy) ...[
              const SizedBox(height: 16),
              const Center(child: CircularProgressIndicator()),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            if (data == null && _error == null && !_busy) ...[
              const SizedBox(height: 16),
              const Text(
                '输入站点首页网址并开始爬取，这里会展示本次爬到的实际数据：'
                '站点地址、页面结构、分类、列表项与详情字段。数据齐全时可以'
                '一键生成 TVBox 蜘蛛源码并保存成文件。',
              ),
            ],
            if (data != null) ...[
              const SizedBox(height: 16),
              _buildGenerateCard(data, blockers ?? const <String>[]),
              if (data.structureError != null) ...[
                const SizedBox(height: 12),
                _buildWarning(data.structureError!),
              ],
              const SizedBox(height: 16),
              _buildSectionTitle('站点信息'),
              _buildInfoRow('站名', data.siteName),
              _buildInfoRow('地址', data.base),
              if (data.pageTitle != null && data.pageTitle!.isNotEmpty)
                _buildInfoRow('首页标题', data.pageTitle!),
              _buildInfoRow(
                '类型',
                data.isMacCMS ? 'MacCMS 采集接口' : '网页',
              ),
              if (data.hasPagination) _buildInfoRow('翻页', '已探到翻页规律'),
              if (data.searchUrl != null)
                _buildInfoRow('搜索地址', data.searchUrl!),
              if (data.categories.isNotEmpty) ...[
                const SizedBox(height: 16),
                _buildSectionTitle('分类（${data.categories.length} 个）'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: data.categories
                      .map(
                        (c) => Chip(label: Text('${c.name}（${c.id}）')),
                      )
                      .toList(),
                ),
              ],
              if (data.listItems.isNotEmpty) ...[
                const SizedBox(height: 16),
                _buildSectionTitle('列表项（${data.listItems.length} 个）'),
                ...data.listItems.take(6).map(_buildListItem),
              ],
              if (data.detailSample != null) ...[
                const SizedBox(height: 16),
                _buildSectionTitle('详情示例'),
                const SizedBox(height: 8),
                _buildDetailSample(data.detailSample!, data.playChain),
              ],
              if (data.links.isNotEmpty) ...[
                const SizedBox(height: 16),
                _buildSectionTitle('页面链接（${data.links.length} 个）'),
                const SizedBox(height: 8),
                ...data.links.take(5).map(
                      (link) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '${link.text} — ${link.url}',
                          style: const TextStyle(fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
              ],
              if (data.evidence.isNotEmpty) ...[
                const SizedBox(height: 16),
                _buildSectionTitle('识别证据'),
                const SizedBox(height: 8),
                ...data.evidence.map(
                  (line) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '• $line',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGenerateCard(ScrapedSiteData data, List<String> blockers) {
    final ready = blockers.isEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '一键生成 py 蜘蛛',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (ready)
              const Text('本次爬取的数据齐全，可以生成蜘蛛源码。')
            else ...[
              const Text('数据不足，暂不能生成，缺以下几项：'),
              const SizedBox(height: 4),
              ...blockers.map(
                (reason) => Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text('• $reason', style: const TextStyle(fontSize: 12)),
                ),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('web-scrape-generate'),
              onPressed: ready ? _generate : null,
              icon: const Icon(Icons.code_rounded),
              label: const Text('一键生成 py'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWarning(String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '结构识别未完成：$message\n以下为通用爬取的部分数据，生成蜘蛛前需补齐结构。',
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 72, child: Text(label)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _buildListItem(ScrapedListItem item) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: _buildThumb(item.cover),
      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(item.url, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  Widget _buildThumb(String cover) {
    if (cover.isEmpty) {
      return const SizedBox(
        width: 48,
        height: 64,
        child: Icon(Icons.image_not_supported_outlined),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        cover,
        width: 48,
        height: 64,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const SizedBox(
          width: 48,
          height: 64,
          child: Icon(Icons.broken_image_outlined),
        ),
      ),
    );
  }

  Widget _buildDetailSample(ScrapedDetailSample sample, PlayChain chain) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildThumb(sample.cover),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                sample.title,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              if (sample.description.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  sample.description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 4),
              Text(
                switch (chain) {
                  PlayChain.directMedia =>
                    '播放链：详情页含直链（${sample.mediaUrls.length} 条）',
                  PlayChain.viaPlayPage =>
                    '播放链：详情页含播放页链接（${sample.playLinks.length} 条示例）',
                  PlayChain.none => '播放链：未发现可播放地址',
                },
                style: const TextStyle(fontSize: 12),
              ),
              for (final link in sample.playLinks)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${link.text} — ${link.url}',
                    style: const TextStyle(fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
