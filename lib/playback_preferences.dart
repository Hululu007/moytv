import 'picture_quality.dart';
import 'video_enhancement_preferences.dart';

const playbackSpeeds = [.5, .75, 1.0, 1.25, 1.5, 2.0, 3.0];
const holdSpeeds = [1.5, 2.0, 2.5, 3.0];
const swipeSeekChoices = [15, 30, 60, 120];

enum TelevisionDecoder { optimized, hardware, software }

enum PlaybackOrientationMode {
  auto('自动'),
  portrait('锁竖屏'),
  landscape('锁横屏');

  const PlaybackOrientationMode(this.label);
  final String label;
}

String speedLabel(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();

class PlaybackPreferences {
  const PlaybackPreferences({
    this.speed = 1,
    this.quality = 0,
    this.autoAdvance = true,
    this.danmaku = true,
    this.preload = true,
    this.seamless = false,
    this.adBlock = true,
    this.holdSpeed = 2,
    this.swipeSeekSeconds = 60,
    this.autoPictureInPicture = true,
    this.enhancement = const VideoEnhancementPreferences(),
    this.pictureQuality = const PictureQualityPreferences(),
    this.televisionDecoder = TelevisionDecoder.optimized,
    this.orientationMode = PlaybackOrientationMode.auto,
  });

  final double speed;
  final int quality;
  final bool autoAdvance;
  final bool danmaku;
  final bool preload;

  /// 无缝播放：换集时用待命播放器已预热好的首帧直接衔接，不黑屏。
  /// 单向依赖 preload：无缝开着预加载必须开，关预加载连带关无缝
  /// （见 [withPreload] / [withSeamless] 与 fromJson 的归一化），
  /// 任何入口都不许存下 seamless=true 而 preload=false 的组合。
  final bool seamless;
  final bool adBlock;
  final double holdSpeed;
  final int swipeSeekSeconds;
  final bool autoPictureInPicture;
  final VideoEnhancementPreferences enhancement;
  final PictureQualityPreferences pictureQuality;
  final TelevisionDecoder televisionDecoder;
  final PlaybackOrientationMode orientationMode;

  PlaybackPreferences copyWith({
    double? speed,
    int? quality,
    bool? autoAdvance,
    bool? danmaku,
    bool? preload,
    bool? seamless,
    bool? adBlock,
    double? holdSpeed,
    int? swipeSeekSeconds,
    bool? autoPictureInPicture,
    VideoEnhancementPreferences? enhancement,
    PictureQualityPreferences? pictureQuality,
    TelevisionDecoder? televisionDecoder,
    PlaybackOrientationMode? orientationMode,
  }) => PlaybackPreferences(
    speed: speed ?? this.speed,
    quality: quality ?? this.quality,
    autoAdvance: autoAdvance ?? this.autoAdvance,
    danmaku: danmaku ?? this.danmaku,
    preload: preload ?? this.preload,
    seamless: seamless ?? this.seamless,
    adBlock: adBlock ?? this.adBlock,
    holdSpeed: holdSpeed ?? this.holdSpeed,
    swipeSeekSeconds: swipeSeekSeconds ?? this.swipeSeekSeconds,
    autoPictureInPicture: autoPictureInPicture ?? this.autoPictureInPicture,
    enhancement: enhancement ?? this.enhancement,
    pictureQuality: pictureQuality ?? this.pictureQuality,
    televisionDecoder: televisionDecoder ?? this.televisionDecoder,
    orientationMode: orientationMode ?? this.orientationMode,
  );

  /// 改预加载开关：关预加载连带关无缝（无缝靠预加载备好的
  /// 下一集 plan 预热，预加载关了无缝无从谈起）；开预加载不动无缝。
  PlaybackPreferences withPreload(bool value) =>
      copyWith(preload: value, seamless: value ? seamless : false);

  /// 改无缝开关：开无缝自动同时打开预加载；关无缝不动预加载。
  PlaybackPreferences withSeamless(bool value) =>
      copyWith(seamless: value, preload: value ? true : preload);

  Map<String, dynamic> toJson() => {
    'speed': speed,
    'quality': quality,
    'autoAdvance': autoAdvance,
    'danmaku': danmaku,
    'preload': preload,
    'seamless': seamless,
    'adBlock': adBlock,
    'holdSpeed': holdSpeed,
    'swipeSeekSeconds': swipeSeekSeconds,
    'autoPictureInPicture': autoPictureInPicture,
    'enhancement': enhancement.toJson(),
    'pictureQuality': pictureQuality.toJson(),
    'televisionDecoder': televisionDecoder.name,
    'orientationMode': orientationMode.name,
  };

  factory PlaybackPreferences.fromJson(Map<String, dynamic> value) {
    final speed = (value['speed'] as num? ?? 1).toDouble();
    final quality = value['quality'] as int? ?? 0;
    final autoAdvance = value['autoAdvance'] as bool? ?? true;
    final danmaku = value['danmaku'] as bool? ?? true;
    final preload = value['preload'] as bool? ?? true;
    // 归一化单向依赖：存量数据里若出现无缝开着而预加载关着的
    // 组合，按「关预加载连带关无缝」读成无缝关，不让矛盾状态进门。
    final seamless = (value['seamless'] as bool? ?? false) && preload;
    final adBlock = value['adBlock'] as bool? ?? true;
    final holdSpeed = (value['holdSpeed'] as num? ?? 2).toDouble();
    final swipeSeekSeconds = value['swipeSeekSeconds'] as int? ?? 60;
    final autoPictureInPicture = value['autoPictureInPicture'] as bool? ?? true;
    if (!playbackSpeeds.contains(speed) ||
        !holdSpeeds.contains(holdSpeed) ||
        !swipeSeekChoices.contains(swipeSeekSeconds) ||
        quality < 0 ||
        quality > 4320) {
      throw const FormatException('播放偏好无效');
    }
    return PlaybackPreferences(
      speed: speed,
      quality: quality,
      autoAdvance: autoAdvance,
      danmaku: danmaku,
      preload: preload,
      seamless: seamless,
      adBlock: adBlock,
      holdSpeed: holdSpeed,
      swipeSeekSeconds: swipeSeekSeconds,
      autoPictureInPicture: autoPictureInPicture,
      enhancement: VideoEnhancementPreferences.fromJson(value['enhancement']),
      pictureQuality: PictureQualityPreferences.fromJson(
        value['pictureQuality'],
      ),
      televisionDecoder:
          TelevisionDecoder.values.asNameMap()[value['televisionDecoder']] ??
          TelevisionDecoder.optimized,
      orientationMode:
          PlaybackOrientationMode.values
              .asNameMap()[value['orientationMode']] ??
          PlaybackOrientationMode.auto,
    );
  }
}
