import 'dart:convert';

import 'package:flutter/foundation.dart';

/// TVBox 视频列表 JSON（`{"list": [...], "parse": 0, "jx": 0}`）的
/// 导入支撑：容错解析、站名推导、成人判定、本地列表蜘蛛模板。
///
/// 每条含 vod_id / vod_name / vod_pic / vod_actor / vod_director /
/// vod_remarks / vod_pubdate / vod_area / vod_year / vod_content /
/// vod_play_from / vod_play_url / type_name；vod_play_url 是拼串
/// `名称$地址#名称$地址…`（`#` 分集、`$` 分名址，parse=0 直接播）。
/// 详情与播放的拆串由 PyContract 现成逻辑承接，这里只负责把文件
/// 变成一个可注册的本地站：导入时生成一只读盘蜘蛛（见模板），
/// 站点走整条 py 链（目录/详情/搜索/取流），不另起引擎。

class JsonListParseResult {
  const JsonListParseResult({
    required this.items,
    required this.skipped,
    required this.damaged,
    this.hasListShape = false,
  });

  /// 解析出的可用条目（每条都是原始 JSON 对象，原样进详情）。
  final List<Map<String, dynamic>> items;

  /// 容错扫描时跳过的损坏条目数（整文解析成功时为 0）。
  final int skipped;

  /// 是否走过容错路径（坏字节/非法 JSON 导致整文解析失败）。
  final bool damaged;

  /// 顶层是不是列表形态（Map 且 list 是 List，含空列表）：
  /// 有形态但无可用条目时，导入报“列表为空”而不是“无法识别”。
  final bool hasListShape;
}

/// 一条可用条目：有 vod_play_url 才能播；vod_id/vod_name 至少其一。
bool isUsableVideoListItem(Object? row) {
  if (row is! Map) return false;
  final playUrl = row['vod_play_url'];
  if (playUrl is! String || playUrl.trim().isEmpty) return false;
  final id = row['vod_id'];
  final name = row['vod_name'];
  final hasId = id != null && '$id'.trim().isNotEmpty;
  final hasName = name is String && name.trim().isNotEmpty;
  return hasId || hasName;
}

/// 列表里是否至少有一条可播条目（视频列表的裁决条件）。
bool hasUsableVideoListItem(List<Map<String, dynamic>> items) =>
    items.any(isUsableVideoListItem);

/// 已解码的 JSON 对象是不是视频列表：顶层有非空 list，且至少
/// 一条可用。TVBox 配置（sites/spider）、书源、海阔规则都没有
/// 这种形态，可作判定签名。
bool looksLikeVideoListJson(Object? decoded) {
  if (decoded is! Map) return false;
  final list = decoded['list'];
  if (list is! List || list.isEmpty) return false;
  return list.any(isUsableVideoListItem);
}

List<Map<String, dynamic>> _asItemMaps(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final row in raw)
      if (row is Map<String, dynamic>) row
      else if (row is Map) Map<String, dynamic>.from(row),
  ];
}

/// 容错解析：整文解析 → 宽容解码整文解析 → 大括号匹配逐条扫描。
/// 损坏只丢损坏的条目，不整文件报废；58MB 大文件调用方走
/// [parseJsonListBytesAsync]（isolate，不卡界面）。
JsonListParseResult parseJsonListBytes(List<int> bytes) {
  try {
    final text = utf8.decode(bytes);
    final doc = jsonDecode(text);
    if (doc is Map<String, dynamic>) {
      final hasListShape = doc['list'] is List;
      if (looksLikeVideoListJson(doc)) {
        return JsonListParseResult(
          items: _asItemMaps(doc['list']),
          skipped: 0,
          damaged: false,
          hasListShape: hasListShape,
        );
      }
      if (hasListShape) {
        return JsonListParseResult(
          items: const [],
          skipped: 0,
          damaged: false,
          hasListShape: true,
        );
      }
    }
  } catch (_) {}
  try {
    final text = utf8.decode(bytes, allowMalformed: true);
    final doc = jsonDecode(text);
    if (doc is Map<String, dynamic>) {
      final hasListShape = doc['list'] is List;
      if (looksLikeVideoListJson(doc)) {
        return JsonListParseResult(
          items: _asItemMaps(doc['list']),
          skipped: 0,
          damaged: true,
          hasListShape: hasListShape,
        );
      }
      if (hasListShape) {
        return JsonListParseResult(
          items: const [],
          skipped: 0,
          damaged: true,
          hasListShape: true,
        );
      }
    }
  } catch (_) {}
  return _scanJsonListItems(utf8.decode(bytes, allowMalformed: true));
}

/// 逐条扫描：只认 `"list": [` 后的顶层 `{...}` 对象，逐个
/// jsonDecode，坏的跳过（计数进 skipped），好的全收。字符串内
/// 的 `{`/`}`/`"` 不参与深度计算，转义 `\"` 不闭合字符串。
JsonListParseResult _scanJsonListItems(String text) {
  final items = <Map<String, dynamic>>[];
  var skipped = 0;
  final listAt = text.indexOf('"list"');
  if (listAt < 0) {
    return JsonListParseResult(items: items, skipped: 0, damaged: true);
  }
  final openAt = text.indexOf('[', listAt);
  if (openAt < 0) {
    return JsonListParseResult(items: items, skipped: 0, damaged: true);
  }
  var depth = 0;
  var objStart = -1;
  var inStr = false;
  var esc = false;
  for (var j = openAt; j < text.length; j++) {
    final c = text[j];
    if (inStr) {
      if (esc) {
        esc = false;
      } else if (c == '\\') {
        esc = true;
      } else if (c == '"') {
        inStr = false;
      }
      continue;
    }
    if (c == '"') {
      inStr = true;
    } else if (c == '{') {
      if (depth == 0) objStart = j;
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0 && objStart >= 0) {
        try {
          final obj = jsonDecode(text.substring(objStart, j + 1));
          if (obj is Map<String, dynamic>) {
            items.add(obj);
          } else if (obj is Map) {
            items.add(Map<String, dynamic>.from(obj));
          }
        } catch (_) {
          skipped++;
        }
        objStart = -1;
      }
    } else if (c == ']' && depth == 0) {
      break;
    }
  }
  return JsonListParseResult(items: items, skipped: skipped, damaged: true);
}

/// isolate 入口：只返回可跨 isolate 传递的 plain Map。
Map<String, dynamic> parseJsonListBytesIsolated(List<int> bytes) {
  final result = parseJsonListBytes(bytes);
  return {
    'items': result.items,
    'skipped': result.skipped,
    'damaged': result.damaged,
    'hasListShape': result.hasListShape,
  };
}

/// 大文件（>1MB）放 isolate 解析，小文件直接解析。
Future<JsonListParseResult> parseJsonListBytesAsync(List<int> bytes) async {
  if (bytes.length <= 1024 * 1024) return parseJsonListBytes(bytes);
  final raw = await compute(parseJsonListBytesIsolated, bytes);
  return JsonListParseResult(
    items: _asItemMaps(raw['items']),
    skipped: raw['skipped'] as int? ?? 0,
    damaged: raw['damaged'] as bool? ?? false,
    hasListShape: raw['hasListShape'] as bool? ?? false,
  );
}

/// 站名推导（只从内容取，不拿文件名乱码当站名）：
/// 1. 单条文件取该条 vod_name（“直播”/“AV”）；
/// 2. 多条取最常见 vod_play_from（hsck），且该值占一半以上；
/// 3. 同一 vod_play_from 下只有一个 type_name 时加 `·<type_name>`
///    后缀消歧义（9 个 hsck 文件否则全叫一个名）；
/// 4. 前两条都取不到时回落文件名：去前导 `_`/数字后仍是乱码
///    短 token（`sl9n` 这种）的不用，改叫“JSON列表”。
String deriveStationName(
  List<Map<String, dynamic>> items,
  String fileName,
) {
  if (items.length == 1) {
    final only = (items.first['vod_name'] as String? ?? '').trim();
    if (only.isNotEmpty) return only;
  }
  final counts = <String, int>{};
  for (final item in items) {
    final from = (item['vod_play_from'] as String? ?? '').trim();
    if (from.isEmpty) continue;
    counts[from] = (counts[from] ?? 0) + 1;
  }
  if (counts.isNotEmpty) {
    final top = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    if (top.value * 2 >= items.length) {
      var base = top.key;
      final types = {
        for (final item in items)
          (item['type_name'] as String? ?? '').trim(),
      }..remove('');
      if (types.length == 1) base = '$base·${types.single}';
      return base;
    }
  }
  var stem = fileName;
  final dot = stem.lastIndexOf('.');
  if (dot > 0) stem = stem.substring(0, dot);
  stem = stem.replaceAll(RegExp(r'^[\d_]+'), '').trim();
  if (stem.isEmpty || RegExp(r'^[a-z0-9]{1,8}$').hasMatch(stem)) {
    return 'JSON列表';
  }
  return stem;
}

/// 成人判定（只决定显示名加不加 🔞，不删任何条目）：
/// vod_play_from 是树内已知成人站键 hsck，或任一 type_name 含
/// “有码/无码”，或推导出的站名就是 AV。
bool isAdultJsonList(List<Map<String, dynamic>> items, String baseName) {
  if (baseName.toLowerCase() == 'av') return true;
  for (final item in items) {
    final from = (item['vod_play_from'] as String? ?? '').trim().toLowerCase();
    if (from == 'hsck') return true;
    final type = (item['type_name'] as String? ?? '').trim();
    if (type.contains('有码') || type.contains('无码')) return true;
  }
  return false;
}

/// 显示名：成人站加 🔞 前缀（与树内成人站同一口径，午夜区凭
/// 这个前缀识别），非成人站原样。
String jsonListDisplayName(
  List<Map<String, dynamic>> items,
  String fileName,
) {
  final base = deriveStationName(items, fileName);
  if (isAdultJsonList(items, base) && !base.startsWith('🔞')) {
    return '🔞$base';
  }
  return base;
}

/// 蜘蛛 ext：JSON 串，含存盘的列表文件绝对路径与显示名。
/// 蜘蛛 init 里解析；ext 变了宿主自动重载蜘蛛。
String jsonListExtFor({required String path, required String name}) =>
    jsonEncode({'path': path, 'name': name});

/// 从 ext 里取列表文件绝对路径；ext 不是 JSON 时当作老式纯路径
/// 兼容处理，取不到返回空串。
String jsonListPathFromExt(String ext) {
  if (ext.isEmpty) return '';
  try {
    final decoded = jsonDecode(ext);
    if (decoded is Map) return (decoded['path'] as String? ?? '').trim();
  } catch (_) {}
  return ext.trim();
}

/// 本地列表蜘蛛源码：读盘（init 传来的路径）+ 内存缓存 + 分页。
/// 14 方法全齐（Dart 侧 validatePySource 与宿主 validate_source
/// 都直接通过）；零中文注释（用户铁律）；不联网、不嗅探，
/// playerContent 只回 parse=0 的直链。
/// 导入时规范化后的存盘文件已是合法 JSON，`json.load` 一次即成；
/// `_scan` 只是读盘又坏了时的兜底，与 Dart 侧同一套大括号匹配。
String buildJsonListSpiderSource() => _jsonListSpiderTemplate;

const String _jsonListSpiderTemplate = r'''try:
    from base.spider import BaseSpider
except Exception:
    class BaseSpider:
        pass

import json


class Spider(BaseSpider):
    def __init__(self):
        self._path = ""
        self._name = ""
        self._items = None
        self._by_id = None
        self._cats = None
        self._page_size = 20

    def getName(self):
        return self._name or "JSON List"

    def init(self, extend=""):
        self._path = ""
        self._name = ""
        self._items = None
        self._by_id = None
        self._cats = None
        try:
            info = json.loads(extend or "")
        except Exception:
            info = None
        if isinstance(info, dict):
            self._path = str(info.get("path") or "")
            self._name = str(info.get("name") or "")
        elif isinstance(extend, str) and extend.strip():
            self._path = extend.strip()

    def _load(self):
        if self._items is not None:
            return self._items
        items = []
        try:
            with open(self._path, "r", encoding="utf-8") as handle:
                doc = json.load(handle)
            raw = doc.get("list") if isinstance(doc, dict) else None
            if isinstance(raw, list):
                items = [it for it in raw if isinstance(it, dict)]
        except Exception:
            items = self._scan()
        self._items = items
        self._by_id = {}
        for it in items:
            key = str(it.get("vod_id"))
            if key not in self._by_id:
                self._by_id[key] = it
        return items

    def _scan(self):
        try:
            with open(self._path, "rb") as handle:
                text = handle.read().decode("utf-8", "replace")
        except Exception:
            return []
        start = text.find('"list"')
        if start < 0:
            return []
        i = text.find("[", start)
        if i < 0:
            return []
        items = []
        depth = 0
        obj_start = -1
        instr = False
        esc = False
        for j in range(i, len(text)):
            c = text[j]
            if instr:
                if esc:
                    esc = False
                elif c == "\\":
                    esc = True
                elif c == '"':
                    instr = False
                continue
            if c == '"':
                instr = True
            elif c == "{":
                if depth == 0:
                    obj_start = j
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0 and obj_start >= 0:
                    try:
                        obj = json.loads(text[obj_start:j + 1])
                    except Exception:
                        obj = None
                    if isinstance(obj, dict):
                        items.append(obj)
                    obj_start = -1
            elif c == "]" and depth == 0:
                break
        return items

    def _categories(self):
        if self._cats is not None:
            return self._cats
        seen = []
        for it in self._load():
            name = str(it.get("type_name") or "").strip()
            if name and name not in seen:
                seen.append(name)
        self._cats = seen
        return seen

    def _page(self, rows, pg):
        try:
            page = int(pg)
        except Exception:
            page = 1
        if page < 1:
            page = 1
        total = len(rows)
        pages = (total + self._page_size - 1) // self._page_size
        if pages < 1:
            pages = 1
        start = (page - 1) * self._page_size
        return {
            "list": rows[start:start + self._page_size],
            "page": page,
            "pagecount": pages,
        }

    def homeContent(self, filter=None):
        cats = [
            {"type_id": name, "type_name": name}
            for name in self._categories()
        ]
        result = {"class": cats, "filters": {}}
        result.update(self._page(self._load(), 1))
        return result

    def homeVideoContent(self):
        return {"list": self._load()[: self._page_size]}

    def categoryContent(self, tid=None, pg=1, filter=None, extend=None):
        tid = str(tid or "")
        rows = self._load()
        if tid:
            rows = [it for it in rows if str(it.get("type_name") or "") == tid]
        return self._page(rows, pg)

    def detailContent(self, ids=None):
        wanted = None
        if isinstance(ids, (list, tuple)) and ids:
            wanted = str(ids[0])
        elif ids:
            wanted = str(ids)
        row = None
        if wanted is not None:
            self._load()
            row = (self._by_id or {}).get(wanted)
        return {"list": [row] if row else []}

    def searchContent(self, key=None, quick=False, pg="1"):
        word = str(key or "").strip().lower()
        rows = self._load()
        if word:
            rows = [
                it
                for it in rows
                if word in str(it.get("vod_name") or "").lower()
                or word in str(it.get("vod_actor") or "").lower()
            ]
        return self._page(rows, pg)

    def playerContent(self, flag=None, id=None, vipFlags=None):
        url = str(id or "").strip()
        return {"parse": 0, "jx": 0, "url": url, "header": {}}

    def getDependence(self):
        return []

    def destroy(self):
        return None

    def localProxy(self, param=None):
        return [404, "text/plain", "localProxy not implemented", {}]

    def isVideoFormat(self, url=None):
        path = str(url or "").split("?")[0].lower()
        return path.endswith(
            (".m3u8", ".mp4", ".mp3", ".flv", ".mkv", ".mov", ".ts", ".aac")
        )

    def manualVideoCheck(self):
        return False

    def action(self, action=None):
        return ""
''';
