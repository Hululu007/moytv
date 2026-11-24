import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/episode_preview_card.dart';

void main() {
  // 详情页与播放页共用同一档选集帧尺寸（用户令：两边一致）。
  test('preview card width is one notch smaller', () {
    expect(episodePreviewCardWidth, 84);
  });

  test('preview columns scale with width', () {
    // 2026-11-24 选集预览图小一档：单卡约 64 宽，360/390 宽手机 5 列。
    expect(episodePreviewColumns(390), 5);
    expect(episodePreviewColumns(360), 5);
    expect(episodePreviewColumns(800), 5);
    expect(episodePreviewColumns(200), 2);
  });
}
