import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class AiAssistantEntry {
  const AiAssistantEntry({required this.name, required this.url});

  final String name;
  final String url;
}

const List<AiAssistantEntry> aiAssistantEntries = [
  AiAssistantEntry(name: 'DeepSeek', url: 'https://chat.deepseek.com/'),
  AiAssistantEntry(name: 'Z.ai', url: 'https://chat.z.ai/'),
  AiAssistantEntry(name: '通义', url: 'https://tongyi.aliyun.com/'),
];

class AiAssistantScreen extends StatefulWidget {
  const AiAssistantScreen({super.key});

  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends State<AiAssistantScreen> {
  AiAssistantEntry? _selected;
  WebViewController? _controller;

  void _select(AiAssistantEntry entry) {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse(entry.url));
    setState(() {
      _selected = entry;
      _controller = controller;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 助手')),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                for (final entry in aiAssistantEntries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      key: ValueKey('ai-entry-${entry.name}'),
                      label: Text(entry.name),
                      selected: _selected?.url == entry.url,
                      onSelected: (selected) {
                        if (selected) _select(entry);
                      },
                    ),
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '打开公开 AI 聊天页，用你自己的账号在网页里登录，本应用不保存任何账号。',
              style: TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _controller == null
                ? const Center(child: Text('选一个入口开始'))
                : WebViewWidget(controller: _controller!),
          ),
        ],
      ),
    );
  }
}
