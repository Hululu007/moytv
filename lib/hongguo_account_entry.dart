import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core_bridge.dart';
import 'hongguo_account.dart';
import 'hongguo_account_store.dart';
import 'hongguo_login_page.dart';
import 'models.dart';

class HongguoAccountEntry extends StatelessWidget {
  const HongguoAccountEntry({
    super.key,
    required this.controller,
    required this.repository,
  });

  final HongguoAccountController controller;
  final AppRepository repository;

  Future<void> _openLogin(BuildContext context) async {
    final preferences = await SharedPreferences.getInstance();
    final accountStore = HongguoAccountStore(
      repository: repository,
      preferences: preferences,
    );
    try {
      await accountStore.load();
    } catch (_) {}
    if (!context.mounted) return;
    await Navigator.of(context).push<HongguoAccount>(
      MaterialPageRoute<HongguoAccount>(
        builder:
            (_) => HongguoLoginPage(
              repository: repository,
              accountStore: accountStore,
              accountController: controller,
            ),
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('退出登录'),
            content: const Text('退出后停止上传云端进度，本机历史保留。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('退出'),
              ),
            ],
          ),
    );
    if (confirmed == true) {
      await controller.logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<HongguoAccount?>(
      valueListenable: hongguoAccountNotifier,
      builder: (context, account, _) {
        if (account == null || !account.loggedIn) {
          return ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person)),
            title: const Text('红果账号'),
            subtitle: const Text('未登录，登录后同步收藏与观看进度'),
            trailing: FilledButton(
              onPressed: () => _openLogin(context),
              child: const Text('登录'),
            ),
          );
        }
        return ListTile(
          leading: CircleAvatar(
            child: Text(
              account.displayName.isNotEmpty
                  ? account.displayName.characters.first
                  : '红',
            ),
          ),
          title: Text(account.displayName),
          subtitle: Text(
            [
              if (account.maskedPhone.isNotEmpty) account.maskedPhone,
              account.methodLabel,
            ].join(' · '),
          ),
          trailing: TextButton(
            onPressed: () => _confirmLogout(context),
            child: const Text('退出登录'),
          ),
          onTap: () => _openLogin(context),
        );
      },
    );
  }
}

class HongguoAccountCloudSection extends StatelessWidget {
  const HongguoAccountCloudSection({
    super.key,
    required this.controller,
    required this.onOpenDrama,
  });

  final HongguoAccountController controller;
  final ValueChanged<Drama> onOpenDrama;

  String _clock(int seconds) {
    final total = seconds < 0 ? 0 : seconds;
    final minutes = total ~/ 60;
    final rest = total % 60;
    String two(int value) => value.toString().padLeft(2, '0');
    if (minutes >= 60) {
      return '${two(minutes ~/ 60)}:${two(minutes % 60)}:${two(rest)}';
    }
    return '${two(minutes)}:${two(rest)}';
  }

  Future<void> _openCloudHistory(BuildContext context) async {
    final history = controller.cloudHistory;
    if (history.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      builder:
          (sheetContext) => SafeArea(
            child: ListView(
              children: [
                const ListTile(title: Text('云端历史续播')),
                for (final item in history)
                  ListTile(
                    title: Text(
                      item.title.isEmpty ? item.seriesId : item.title,
                    ),
                    subtitle: Text(
                      '第 ${item.episodeIndex + 1} 集 · ${_clock(item.positionSeconds.round())}'
                      '${item.durationMs > 0 ? ' / ${_clock((item.durationMs / 1000).round())}' : ''}',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      onOpenDrama(
                        Drama(
                          id: 'hongguo:${item.seriesId}',
                          source: 'hongguo',
                          title:
                              item.title.isEmpty
                                  ? item.seriesId
                                  : item.title,
                          cover: item.cover,
                          episodes: item.episodeCount,
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final canOpenHistory = controller.cloudHistory.isNotEmpty;
        return Column(
          children: [
            ListTile(
              leading: const Icon(Icons.favorite),
              title: const Text('账户收藏'),
              trailing: Text('${controller.cloudFavorites.length} 部'),
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('云端历史续播'),
              trailing: Text('${controller.cloudHistory.length} 部'),
              onTap:
                  canOpenHistory ? () => _openCloudHistory(context) : null,
            ),
            ListTile(
              leading: const Icon(Icons.event_available),
              title: const Text('已上线预约'),
              trailing: Text('${controller.onlineReservations.length} 部'),
            ),
            ListTile(
              leading: const Icon(Icons.event),
              title: const Text('待上线预约'),
              trailing: Text('${controller.upcomingReservations.length} 部'),
            ),
            if (controller.pendingUploads.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.cloud_upload),
                title: const Text('待上传进度'),
                trailing: Text('${controller.pendingUploads.length} 条'),
              ),
          ],
        );
      },
    );
  }
}
