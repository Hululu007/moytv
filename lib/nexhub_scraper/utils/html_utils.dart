// 移植自 NexHub（https://github.com/nexhub-app/NexHub，提交 37ddbdd，Apache-2.0）。
// 原始路径：lib/core/utils/html_utils.dart。
// 移植状态：改编——魔蚁无 xpath_selector / xpath_selector_html_parser 依赖，
// XPath 分支改为抛 UnsupportedError（调用方必须用 CSS 选择器）；CSS 选择器路径、
// clean、queryAttrExpr 的 CSS 部分与原文一致。isXPath 保留，用于路由判定。
/// HTML / CSS selector utilities（本移植版：仅 CSS 选择器可用）。
///
/// 原文还支持 XPath（`xpath_selector_html_parser` 引擎）；魔蚁未接入该引擎，
/// XPath 选择器会抛 [UnsupportedError]，不要把 XPath 选择器传进来。
library;

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

class HtmlUtils {
  HtmlUtils._();

  static Document parse(String html) => html_parser.parse(html);

  /// Returns matching elements (for per-field extraction by the parser).
  ///
  /// XPath selectors are NOT supported in this port (see file header) and
  /// throw [UnsupportedError]; CSS selectors use `querySelectorAll`.
  static List<Element> elements(String html, String selector) {
    final doc = parse(html);
    if (isXPath(selector)) return _xpathElements(doc, selector);
    return doc.querySelectorAll(selector);
  }

  static String? query(String html, String selector) {
    final doc = parse(html);
    if (isXPath(selector)) return _xpathQuery(doc, selector);
    return doc.querySelector(selector)?.text.trim();
  }

  static List<String> queryAll(String html, String selector) {
    final doc = parse(html);
    if (isXPath(selector)) return _xpathQueryAll(doc, selector);
    return doc
        .querySelectorAll(selector)
        .map((e) => e.text.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static String? queryAttr(String html, String selector, String attr) {
    final doc = parse(html);
    if (isXPath(selector)) return _xpathAttr(doc, selector, attr);
    return doc.querySelector(selector)?.attributes[attr];
  }

  /// Returns the **inner HTML** of the first element matched by [selector].
  /// Used by `context.dom.queryHtml` (golden 老格式 novel scripts) to grab a
  /// markup fragment (e.g. the novel-content `<div>`) for later cleaning.
  /// Unlike [query] (which returns trimmed text), this preserves the markup.
  static String? queryHtml(String html, String selector) {
    final doc = parse(html);
    final Element? el;
    if (isXPath(selector)) {
      final nodes = _xpathElements(doc, selector);
      el = nodes.isEmpty ? null : nodes.first;
    } else {
      el = doc.querySelector(selector);
    }
    return el?.innerHtml;
  }

  /// Strips noise nodes (`script`/`style`/`ins`/`iframe`/`noscript`/`head`/
  /// `link`/`meta`/`svg`) and comments from [html], returning the cleaned
  /// inner HTML. Used by `context.content.clean` (golden novel content
  /// scripts) to sanitise chapter bodies before display.
  static String clean(String html) {
    final doc = parse(html);
    doc
        .querySelectorAll(
            'script, style, ins, iframe, noscript, head, link, meta, svg')
        .forEach((e) => e.remove());
    _removeComments(doc);
    final body = doc.body;
    return body?.innerHtml ?? doc.documentElement?.innerHtml ?? '';
  }

  static void _removeComments(Node node) {
    final comments = node.nodes.whereType<Comment>().toList();
    for (final c in comments) {
      c.remove();
    }
    for (final child in node.nodes.whereType<Element>()) {
      _removeComments(child);
    }
  }

  /// Parses `a@href` / `img@data-src` style composite selectors:
  /// the CSS part matches an element, then `@attr` is read; without `@` the
  /// text is returned. XPath selectors are routed to [query]/[queryAttr]
  /// (and throw in this port).
  ///
  /// XPath expressions (containing `[@...]` predicates or top-level string
  /// functions) must be checked FIRST: their own `@` occurrences (e.g.
  /// `//div[@id='x']/@id`) would otherwise be mis-split as css@attr.
  static String? queryAttrExpr(String html, String expr) {
    if (isXPath(expr)) return query(html, expr);
    final atIndex = expr.indexOf('@');
    if (atIndex < 0) return query(html, expr);
    final css = expr.substring(0, atIndex).trim();
    final attr = expr.substring(atIndex + 1).trim();
    return queryAttr(html, css, attr);
  }

  // ---- XPath branch (unsupported in this port) ----

  /// A selector is treated as XPath when it begins with an XPath path prefix
  /// (`//`, `/`, `./`, `.//`), a top-level XPath string function
  /// (`substring-before(` / `substring-after(`), or contains an XPath
  /// attribute predicate (`[@attr]` / `[@attr='val']`). CSS selectors never
  /// use `[@`, so CSS routing is unaffected.
  static bool isXPath(String selector) {
    final s = selector.trim();
    if (s.startsWith('//') ||
        s.startsWith('./') ||
        s.startsWith('.//') ||
        s.startsWith('/')) {
      return true;
    }
    if (s.startsWith('substring-before(') || s.startsWith('substring-after(')) {
      return true;
    }
    // XPath attribute predicate: tag[@attr] or tag[@attr='val'].
    // CSS uses [attr] without @, so [@ is a safe XPath signal.
    return s.contains('[@');
  }

  static Never _xpathUnsupported(String selector) => throw UnsupportedError(
        'XPath 选择器在魔蚁未接入引擎，无法求值：$selector（请改用 CSS 选择器）',
      );

  static List<Element> _xpathElements(Document doc, String selector) =>
      _xpathUnsupported(selector);

  static String? _xpathQuery(Document doc, String selector) =>
      _xpathUnsupported(selector);

  static List<String> _xpathQueryAll(Document doc, String selector) =>
      _xpathUnsupported(selector);

  static String? _xpathAttr(Document doc, String selector, String attr) =>
      _xpathUnsupported(selector);
}
