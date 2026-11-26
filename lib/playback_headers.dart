/// 播放请求头按播放器核的翻译（目前只有 mpv/media_kit 需要）。
///
/// 背景：115 直链的请求头契约是「播放 UA 必须与取链 UA 一致」，而取链
/// UA 是空串（见 cloud_drive 的 CloudDirectLink.fetchUserAgent）。把
/// `User-Agent: ''` 原样塞进 media_kit 的 Media.httpHeaders，它会拼成
/// `User-Agent: ` 这样一条空值字段，mpv 解析后多半直接丢弃、回落到
/// mpv 自己的默认 UA，f=1 的文件就会被 CDN 拒（403）。
///
/// mpv 的 http-header-fields 里表示「这个头只发名字、不带值、也不要
/// 默认值」的写法是字面量 `User-Agent;`（curl 的空头语法，星辰115 的
/// MPV 适配实证）。media_kit 的字段一律是 `键: 值` 形式，拼不出这个
/// 字面量，所以空 UA 的计划改走 mpv 属性 http-header-fields 直接设
/// 字段表，Media.httpHeaders 里则把 UA 摘掉（其余头仍走 media_kit
/// 自带通道的话会覆盖属性，所以摘掉 UA 后其余头也一并进字段表，
/// Media 不再带任何头）。
library;

/// 计划的请求头是否带空 UA（需要给 mpv 做字面量翻译）。
bool planHasEmptyUserAgent(Map<String, String> headers) =>
    headers.entries.any(
      (e) => e.key.toLowerCase() == 'user-agent' && e.value.isEmpty,
    );

/// 把请求头翻译成 mpv http-header-fields 的字段串列表：
/// 空 UA → 字面量 `User-Agent;`；其余 → `键: 值`。
/// 没有空 UA 时返回 null（调用方走 media_kit 原生通道，不碰属性）。
List<String>? mpvHttpHeaderFields(Map<String, String> headers) {
  if (!planHasEmptyUserAgent(headers)) return null;
  final fields = <String>[];
  var uaWritten = false;
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'user-agent') {
      if (!uaWritten) {
        fields.add('User-Agent;');
        uaWritten = true;
      }
      continue;
    }
    fields.add('${entry.key}: ${entry.value}');
  }
  return fields;
}

/// mpv 字符串列表属性的拼法：逗号分隔，值里的逗号与反斜杠要转义
/// （mpv 按字符串列表解析属性值时，反斜杠转义下一个字符）。
String mpvHeaderFieldsPropertyValue(List<String> fields) => fields
    .map((f) => f.replaceAll('\\', '\\\\').replaceAll(',', '\\,'))
    .join(',');
