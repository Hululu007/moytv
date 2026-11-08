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
    adBlock: adBlock ?? this.adBlock,
    holdSpeed: holdSpeed ?? this.holdSpeed,
    swipeSeekSeconds: swipeSeekSeconds ?? this.swipeSeekSeconds,
    autoPictureInPicture: autoPictureInPicture ?? this.autoPictureInPicture,
    enhancement: enhancement ?? this.enhancement,
    pictureQuality: pictureQuality ?? this.pictureQuality,
    televisionDecoder: televisionDecoder ?? this.televisionDecoder,
    orientationMode: orientationMode ?? this.orientationMode,
  );

  Map<String, dynamic> toJson() => {
    'speed': speed,
    'quality': quality,
    'autoAdvance': autoAdvance,
    'danmaku': danmaku,
    'preload': preload,
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
