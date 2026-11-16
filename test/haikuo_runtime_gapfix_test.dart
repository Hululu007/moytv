import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

/// 海阔运行时缺口修复的落点测试：断言修复代码真实存在于运行时
/// HTML 里（行为级验证受限于无 jsdom 环境，见完工报告）。
void main() {
  final html = haikuoRuntimeHtml;

  void has(String needle) {
    expect(html, contains(needle), reason: '缺失：$needle');
  }

  test('旧有测试钉住的关键串仍在', () {
    has('function isBareJsRule');
    has("trimmed.indexOf('js:') === 0 || isBareJsRule(text)");
    has('!isBareJsRule(rule)');
    has('new Function(code)');
    has('function runSource(source)');
    has('return text;');
  });

  test('搜索：入口、执行、类型标记', () {
    has('function runSearch');
    has('window.__haikuoSearch');
    has("MY_TYPE = 'search'");
    has('searchFind');
    has('function getSearchMode');
    has('function searchContains');
  });

  test('prerule：启动与返回时执行', () {
    has('function runPrerule');
    has('runPrerule();');
    has('seedStorage();');
  });

  test('getParam / clearMyVar / 变量族', () {
    has('function getParam');
    has('function clearMyVar');
    has('function listMyVarKeys');
    has('getParam: getParam');
    has('clearMyVar: clearMyVar');
  });

  test('动态界面：updateItem 一族', () {
    has('function updateItem');
    has('function deleteItem');
    has('function deleteItemByCls');
    has('function addItemAfter');
    has('function addItemBefore');
    has('function findItem');
    has('function findItemsByCls');
    has('updateItem: updateItem');
    has('function rerenderCurrent');
    has('function itemExtraId');
  });

  test('fetch 增强：withHeaders、Cookie、批量、URL 模板', () {
    has('function wrapFetchResult');
    has('withHeaders');
    has('statusCode');
    has('function fetchCookie');
    has('function batchFetch');
    has('function buildUrl');
    has('function fetchPC');
    has('function getCookie');
    has('function setCookie');
    has('function substituteTemplates');
    has('function parseUrlSuffix');
    has('function evalJsTransform');
    has('function rawHttpEx');
    has('function base64ToHex');
    has('/__cookie');
  });

  test('解析链：多段 &&、jQuery 伪类、pd 补全链接', () {
    has('function chainSelect');
    has('HTML_TAG_NAMES');
    has('function parseSelectorSegment');
    has('function parseDom(');
    has('function parseDomForArray');
    has('pd: parseDom');
    has('parseDomForHtml: parseDomForHtml');
    has('parseDoc: parseDoc');
    has('OuterHtml');
  });

  test('声明式规则求值器', () {
    has('function evalDeclarative');
    has('function evalDeclarativeText');
    has('function evalDeclarativePage');
    has('function looksDeclarative');
    has('function runDeclarativeSource');
    has('function fetchPageHtml');
  });

  test('子页：查询串、裸 JS 拓宽、模块收集', () {
    has('function splitPageRef');
    has('function findPage');
    has('function runPageRule');
    has('function collectModuleNames');
    has('function loadModule');
    has('function resolveVirtual');
    has('function stripFlags');
    has('hiker://files/');
    has('hiker://images/');
  });

  test('分类/地区/年份行不再要求 ##', () {
    has('function categoryRowsHtml');
    has('function hasCategoryRows');
    has("parseRulePairs('area_name', 'area_url')");
    has("parseRulePairs('year_name', 'year_url')");
    has('__haikuoSelectArea');
    has('__haikuoSelectYear');
    has('fyarea');
    has('fyyear');
  });

  test('col_type 渲染族与富文本清洗', () {
    has('function sectionHtml');
    has('function cardHtml');
    has('function tileHtml');
    has('function renderDetail');
    has('function isSingleBlockCol');
    has('function sanitizeRichHtml');
    has('function markupTitle');
    has('movie_1_vertical_pic_blur');
    has('text_center_1');
    has('icon_1_search');
    has("new Function('input', code)");
  });

  test('链接路由：hiker/video/webRule/x5Rule/pics/搜索', () {
    has('function handleLinkScheme');
    has('function handleLazyResult');
    has('function openItem');
    has('function renderGallery');
    has('function pushNavigate');
    has('function renderVirtual');
    has('hiker://search');
    has("clean.indexOf('video://') === 0");
    has('webRule://');
    has('x5Rule://');
  });

  test('对话框桥与原生对话框接管', () {
    has('function dialogRequest');
    has('function dialogConfirm');
    has('function dialogAlert');
    has('function dialogInput');
    has('function dialogSelect');
    has('function confirmFn');
    has('function openInputDialog');
    has('function openSelectDialog');
    has('/__dialog');
    has('window.confirm = confirmFn');
    has('window.prompt');
    has('confirm: confirmFn');
    has('alert: dialogAlert');
  });

  test('嗅探契约', () {
    has('function startSniff');
    has('__haikuoSniffResult');
    has('window.__haikuoFileSelected');
  });

  test('refreshPage/sleep 真实现', () {
    has('function refreshPage');
    has('function sleep');
    has('refreshListeners');
    has('closeListeners');
    has('pagehide');
    has('refreshPage: refreshPage');
    has('sleep: sleep');
  });

  test('宿主 API：家地址、规则、错误、返回、复制、配置', () {
    has('function getHome');
    has('function getRule');
    has('function setError');
    has('function back(');
    has('function copyFn');
    has('function getColTypes');
    has('function setPageParams');
    has('function initConfig');
    has('getHome: getHome');
    has('MOBILE_UA');
    has('window0');
  });

  test('存储与文件族', () {
    has('function seedStorage');
    has('function getPublicItem');
    has('function readFile');
    has('function deleteFile');
    has('function fileExist');
    has('function downloadFile');
    has('function convertBase64Image');
  });

  test('远程模块缓存与 m3u8 工具', () {
    has('function requireCache');
    has('function deleteCache');
    has('function fixM3u8');
    has('function cacheM3u8');
  });

  test('摘要、HMAC、xpath、rc4、十六进制', () {
    has('function rc4');
    has('function hexToBytes');
    has('function xpath');
    has('md5: md5');
    has('sha256: sha256');
    has('/__crypto');
  });

  test('CryptoJS 子集工厂', () {
    has('__CRYPTOJS_FACTORY_START__');
    has('function getCryptoJS');
    has('__cryptoJSFactory');
    has('function md5Bytes');
    has('function opensslKDF');
    has('aesCryptBytes');
    has('EvpKDF');
    has('RC4Drop');
    has('Pkcs7');
    has('CryptoJS: CryptoJS');
    has('getCryptoJS: getCryptoJS');
    has('function registerDNS');
  });

  test('末章规则与播放字幕透传', () {
    has('function setLastChapterRule');
    has('setLastChapterRule: setLastChapterRule');
    has('function evalLastChapter');
    has('function showLastChapter');
    has('rule.chapter_find');
    has('function playVideo');
    has('playVideo: playVideo');
    has('download: download');
    has('payload.subtitle');
  });

  test('导航与详情入口', () {
    has('function boot()');
    has('function goBack');
    has('function openDetail');
    has('function setCurrentInput');
    has('function setGlobals');
    has('function showListLoading');
    has('function showLoading');
    has('function hideLoading');
    has('showLoading: showLoading');
  });

  test('\$ 工具箱', () {
    has('function fnSource');
    has('function dateFormatImpl');
    has('function registerLazy');
  });
}
