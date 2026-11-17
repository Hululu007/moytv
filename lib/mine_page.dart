import 'dart:async';

import 'package:flutter/material.dart';

import 'app_theme_config.dart';
import 'core_bridge.dart';
import 'hongguo_account.dart';
import 'hongguo_account_entry.dart';
import 'local_store.dart';
import 'models.dart';
import 'neon_glass_kit.dart';

/// “我的”页：帐户 / 内容 / 外观与设置三组（设置页风格的分段标题 +
/// 圆角分组卡片 + 渐变图标块，跟随主题）。
///
/// 原是 HongguoDramaHome 的内层页签；抽屉拆除后，通用分支点底部栏
/// “我的”也要进同一页，单立成共享页：短剧首页内层与通用分支共用，
/// 条目、行为、key 一字不动。主题切换只在设置页（这里不重复放
/// 入口，设置页的“外观主题”是唯一入口）。
class MinePage extends StatefulWidget {
  const MinePage({
    super.key,
    required this.repository,
    required this.store,
    required this.sourceLabel,
    required this.onOpenDrama,
    required this.onOpenSaved,
    this.onSettingsPressed,
  });

  final AppRepository repository;
  final LocalStore store;

  /// 头像旁的副标题：当前分组名与站数（如“红果 (1)”）。
  final String sourceLabel;
  final ValueChanged<Drama> onOpenDrama;
  final void Function({required bool history}) onOpenSaved;
  final VoidCallback? onSettingsPressed;

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  late final HongguoAccountController _accountController =
      HongguoAccountController.withTransport(
        GoHongguoAccountTransport(widget.repository),
        repository: widget.repository,
      );

  @override
  void initState() {
    super.initState();
    unawaited(_accountController.load());
  }

  @override
  void dispose() {
    _accountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: config.primaryColor.withValues(alpha: 0.16),
                  child: Icon(
                    Icons.person,
                    size: 30,
                    color: config.primaryColor,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '我的',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: config.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.sourceLabel,
                        style: TextStyle(
                          fontSize: 12,
                          color: config.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const NeonSectionTitle('帐户'),
          NeonRowGroup(
            children: [
              HongguoAccountEntry(
                controller: _accountController,
                repository: widget.repository,
              ),
              HongguoAccountCloudSection(
                controller: _accountController,
                onOpenDrama: widget.onOpenDrama,
              ),
            ],
          ),
          const SizedBox(height: 12),
          const NeonSectionTitle('内容'),
          NeonRowGroup(
            children: [
              NeonRow(
                icon: Icons.bookmark_outline,
                title: '追剧',
                onTap: () => widget.onOpenSaved(history: false),
              ),
              NeonRow(
                icon: Icons.history_outlined,
                title: '最近观看',
                onTap: () => widget.onOpenSaved(history: true),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const NeonSectionTitle('外观与设置'),
          NeonRowGroup(
            children: [
              NeonRow(
                icon: Icons.settings_outlined,
                title: '设置',
                onTap: widget.onSettingsPressed,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
