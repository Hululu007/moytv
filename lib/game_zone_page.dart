import 'package:flutter/material.dart';

import 'ra2_game_page.dart';
import 'web_game_page.dart';

/// 游戏区里的两款游戏（用户 2026-11-19 令新增游戏区，只这两款）。
/// 地址只出现在代码里，卡片上只显示游戏名与副标题，不显示网址。
enum GameZoneGame {
  ra2,
  kof;

  /// 卡片与窗口上显示的游戏名。
  String get title => switch (this) {
    GameZoneGame.ra2 => '红警2',
    GameZoneGame.kof => '拳皇97',
  };

  /// 卡片副标题：来源与玩法类型。
  String get subtitle => switch (this) {
    GameZoneGame.ra2 => '网页版 · 即时战略',
    GameZoneGame.kof => '小霸王游戏 · 街机格斗',
  };

  /// 游戏页地址（首请求地址）。
  String get url => switch (this) {
    GameZoneGame.ra2 => ra2GameUrl,
    GameZoneGame.kof => kof97GameUrl,
  };

  /// 唯一放行的导航主机。
  String get host => switch (this) {
    GameZoneGame.ra2 => ra2GameHost,
    GameZoneGame.kof => kof97GameHost,
  };

  /// 加载/失败面板 ValueKey 的前缀，与桌面窗口共用同一套
  ///（红警2 'ra2'、拳皇97 'kof'），键不撞。
  String get keyPrefix => switch (this) {
    GameZoneGame.ra2 => 'ra2',
    GameZoneGame.kof => 'kof',
  };

  /// 卡片图标底块的渐变色：与桌面图标同一套配色（红警2深红、
  /// 拳皇97青绿），区里一眼认得出是哪款。
  List<Color> get gradient => switch (this) {
    GameZoneGame.ra2 => const [Color(0xFFB91C1C), Color(0xFF7F1D1D)],
    GameZoneGame.kof => const [Color(0xFF14B8A6), Color(0xFF0F766E)],
  };
}

/// 游戏区页：两张游戏卡（红警2、拳皇97），点卡进游戏。
/// 本身不带标题栏、不 push 路由：进游戏的动作由调用方
/// [onGameSelected] 决定——普通壳推全屏游戏路由，Win7/XP
/// 桌面壳开对应的游戏窗口（进窗即全屏）。
class GameZonePage extends StatelessWidget {
  const GameZonePage({super.key, required this.onGameSelected});

  final ValueChanged<GameZoneGame> onGameSelected;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        for (final game in GameZoneGame.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _GameCard(
              game: game,
              onTap: () => onGameSelected(game),
            ),
          ),
      ],
    );
  }
}

class _GameCard extends StatelessWidget {
  const _GameCard({required this.game, required this.onTap});

  final GameZoneGame game;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey('game-zone-card-${game.name}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: game.gradient,
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.sports_esports,
                  size: 32,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      game.title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      game.subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
