import 'dart:io';

import 'package:flutter/material.dart';

import 'app_update.dart';

/// 启动后发现新版本时弹的更新提示框。
/// 安卓点“下载并安装”直接在框里下载（带进度）再调系统安装器；
/// 非安卓点“打开发布页”跳去发布页下载。
/// “稍后再说”只记这一个版本，有更新的版本下次启动还会再弹；
/// 强制更新（发布说明里带 FORCE_AFTER/FORCE_UNTIL 且在窗口内）没有
/// “稍后再说”，也不能点框外关掉。
Future<void> showAppUpdatePrompt(
  BuildContext context, {
  required AppVersion current,
  required AppReleaseInfo latest,
}) async {
  final forced = AppUpdateChecker.isForceUpdate(
    current,
    latest,
    DateTime.now(),
  );
  await showDialog<void>(
    context: context,
    barrierDismissible: !forced,
    builder: (dialogContext) {
      var downloading = false;
      var received = 0;
      var total = 0;
      String? error;
      return StatefulBuilder(
        builder: (context, setState) {
          Future<void> downloadAndInstall() async {
            setState(() {
              downloading = true;
              error = null;
              received = 0;
              total = 0;
            });
            try {
              final file = await AppUpdateChecker.downloadApk(
                latest,
                onProgress: (progress) {
                  setState(() {
                    received = progress.received;
                    total = progress.total;
                  });
                },
              );
              await AppUpdateChannel.installApk(file.path);
              if (context.mounted) Navigator.of(context).pop();
            } catch (e) {
              if (context.mounted) {
                setState(() {
                  downloading = false;
                  error = '$e';
                });
              }
            }
          }

          return AlertDialog(
            title: Text('发现新版本 ${latest.version}'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前版本 $current → 最新版本 ${latest.version}'),
                  if (latest.notes.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text('更新说明：\n${latest.notes}'),
                  ],
                  if (forced) ...[
                    const SizedBox(height: 12),
                    Text(
                      '强制更新：请尽快完成更新，否则旧版本将无法继续使用。',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (downloading) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: total > 0 ? received / total : null,
                    ),
                    const SizedBox(height: 6),
                    Text(total > 0 ? '已下载 $received / $total 字节' : '正在下载…'),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              if (!forced)
                TextButton(
                  onPressed: downloading
                      ? null
                      : () async {
                          await AppUpdateChecker.dismissUpdate(latest.version);
                          if (context.mounted) {
                            Navigator.of(context).pop();
                          }
                        },
                  child: const Text('稍后再说'),
                ),
              if (Platform.isAndroid)
                FilledButton(
                  onPressed: downloading ? null : downloadAndInstall,
                  child: Text(downloading ? '下载中…' : '下载并安装'),
                )
              else
                FilledButton(
                  onPressed: () async {
                    final opened = await AppUpdateChannel.openUrl(
                      latest.htmlUrl,
                    );
                    if (!opened && context.mounted) {
                      setState(() => error = '无法打开浏览器，请手动前往发布页');
                    }
                  },
                  child: const Text('打开发布页'),
                ),
            ],
          );
        },
      );
    },
  );
}
