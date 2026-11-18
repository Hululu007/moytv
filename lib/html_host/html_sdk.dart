/// HTML 宿主注入的 fm 桥垫片：页面里的 `fm.*` / `GM_*` 入口。
///
/// ES2017 写法（不用可选链/空值合并），只装在顶层帧；单文件站由
/// 回环服务以 script 标签注入，原站增强站由宿主页面在加载完成后
/// runJavaScript 注入。垫片只负责把调用发给原生通道
/// `MoyiHtmlNative`，不做任何业务判断；但做调用约定归一：位置参数
/// 形态（`fm.req(url, options)` / `fm.play(url, title)` 等渔老写法）
/// 与对象形态双收，归一成对象再发；`fm.res` 按指南同步返回网关
/// 地址字符串（直接在垫片里算，不走异步桥）。
///
/// 垫片内含 `// SHIM_START` / `// SHIM_END` 标记，供 Node 桩验提取。
const String kMoyiHtmlSdkShim = r'''
// SHIM_START
(function () {
  if (window.__moyiFmInstalled) return;
  if (window.top !== window) return;
  window.__moyiFmInstalled = true;
  window.__moyiFmVersion = 1;
  var pending = {};
  var chunks = {};
  var seq = 0;
  function post(method, params) {
    return new Promise(function (resolve, reject) {
      var id = 'fm' + (++seq) + '_' + Date.now() + '_' + Math.floor(Math.random() * 100000);
      pending[id] = { resolve: resolve, reject: reject };
      var payload;
      try {
        payload = JSON.stringify({ id: id, method: method, params: params || {} });
      } catch (e) {
        delete pending[id];
        reject(e);
        return;
      }
      try {
        if (window.MoyiHtmlNative && MoyiHtmlNative.postMessage) {
          MoyiHtmlNative.postMessage(payload);
        } else {
          throw new Error('native bridge unavailable');
        }
      } catch (e) {
        delete pending[id];
        reject(e);
      }
    });
  }
  window.__moyiFmChunk = function (id, idx, total, part) {
    var buf = chunks[id];
    if (!buf) { buf = { parts: [], total: total }; chunks[id] = buf; }
    buf.parts[idx] = part;
    var i;
    for (i = 0; i < buf.total; i++) {
      if (buf.parts[i] === undefined) return;
    }
    var text = buf.parts.join('');
    delete chunks[id];
    window.__moyiFmResolve(id, text);
  };
  window.__moyiFmResolve = function (id, text) {
    var entry = pending[id];
    if (!entry) return;
    delete pending[id];
    var data;
    try {
      data = JSON.parse(text);
    } catch (e) {
      entry.reject(new Error('bad bridge response'));
      return;
    }
    if (data && data.ok) {
      entry.resolve(data.result === undefined ? null : data.result);
    } else {
      entry.reject(new Error((data && data.error) || 'bridge error'));
    }
  };
  window.__moyiExtError = function (id, message) {
    post('fm._exterror', { id: id, message: String(message || '') }).catch(function () {});
  };
  function notifyUrlChange() {
    var url = String(window.location.href || '');
    try {
      document.dispatchEvent(new CustomEvent('fmurlchange', { detail: { url: url } }));
    } catch (e) {}
    post('fm._urlchange', { url: url }).catch(function () {});
  }
  var _pushState = history.pushState;
  var _replaceState = history.replaceState;
  history.pushState = function () {
    var ret = _pushState.apply(this, arguments);
    notifyUrlChange();
    return ret;
  };
  history.replaceState = function () {
    var ret = _replaceState.apply(this, arguments);
    notifyUrlChange();
    return ret;
  };
  window.addEventListener('popstate', notifyUrlChange);
  function isObject(v) { return v !== null && typeof v === 'object' && !Array.isArray(v); }
  function assign(target, source) {
    if (!isObject(source)) return target;
    var keys = Object.keys(source);
    for (var i = 0; i < keys.length; i++) target[keys[i]] = source[keys[i]];
    return target;
  }
  function gatewayPort() {
    var info = window.__moyiSiteInfo || {};
    if (info.gatewayPort) return info.gatewayPort;
    try {
      var loc = window.location || {};
      if ((loc.hostname === '127.0.0.1' || loc.hostname === 'localhost') && loc.port) return loc.port;
    } catch (e) {}
    return 0;
  }
  function utf8Bytes(str) {
    var bytes = [];
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);
      if (c < 0x80) {
        bytes.push(c);
      } else if (c < 0x800) {
        bytes.push(0xC0 | (c >> 6), 0x80 | (c & 0x3F));
      } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < str.length) {
        var c2 = str.charCodeAt(i + 1);
        if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
          var cp = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
          bytes.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
          i++;
        } else {
          bytes.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
        }
      } else {
        bytes.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
      }
    }
    return bytes;
  }
  function base64UrlEncode(str) {
    var bytes = utf8Bytes(str);
    var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    var out = '';
    for (var i = 0; i < bytes.length; i += 3) {
      var b0 = bytes[i];
      var b1 = (i + 1 < bytes.length) ? bytes[i + 1] : 0;
      var b2 = (i + 2 < bytes.length) ? bytes[i + 2] : 0;
      out += chars[b0 >> 2];
      out += chars[((b0 & 3) << 4) | (b1 >> 4)];
      if (i + 1 < bytes.length) out += chars[((b1 & 15) << 2) | (b2 >> 6)];
      if (i + 2 < bytes.length) out += chars[b2 & 63];
    }
    return out.replace(/\+/g, '-').replace(/\//g, '_');
  }
  var fm = {};
  // 双约定：fm.req(url, options)（渔老/DSPlayer 写法）与 fm.req(options)。
  fm.req = function (urlOrOptions, options) {
    if (typeof urlOrOptions === 'string') {
      return post('fm.req', assign({ url: urlOrOptions }, options));
    }
    return post('fm.req', urlOrOptions || {});
  };
  // fm.res 按指南是同步返回字符串：垫片直接算出回环网关地址，
  // 不走异步桥（DOM 的 img.src/video.src 赋值等不了 Promise）。
  // 拿不到网关端口时原样返回原地址（降级，不炸页面）。
  fm.res = function (urlOrOptions, options) {
    var params = {};
    if (typeof urlOrOptions === 'string') {
      params = assign({ url: urlOrOptions }, options);
    } else if (isObject(urlOrOptions)) {
      params = urlOrOptions;
    }
    var url = String(params.url || '');
    if (!url) return '';
    if (url.indexOf('http://') !== 0 && url.indexOf('https://') !== 0) return url;
    var payload = { url: url };
    if (isObject(params.headers)) payload.headers = params.headers;
    if (params.referer) payload.referer = String(params.referer);
    if (params.method) payload.method = String(params.method);
    var port = gatewayPort();
    if (!port) return url;
    return 'http://127.0.0.1:' + port + '/__res?d=' + base64UrlEncode(JSON.stringify(payload));
  };
  // 双约定：fm.play(url, title, options) 与 fm.play(payload)。
  fm.play = function (urlOrPayload, titleOrOptions, options) {
    if (typeof urlOrPayload === 'string') {
      var params = { url: urlOrPayload };
      if (typeof titleOrOptions === 'string') {
        params.title = titleOrOptions;
        assign(params, options);
      } else if (isObject(titleOrOptions)) {
        assign(params, titleOrOptions);
      }
      return post('fm.play', params);
    }
    return post('fm.play', urlOrPayload || {});
  };
  // 双约定：fm.vod(siteKey, vodId, title, pic, options) 与 fm.vod(payload)。
  fm.vod = function (siteKeyOrPayload, vodId, title, pic, options) {
    if (typeof siteKeyOrPayload === 'string') {
      var params = { siteKey: siteKeyOrPayload };
      if (vodId !== undefined && vodId !== null) {
        params.vod_id = String(vodId);
        params.vodId = String(vodId);
      }
      if (typeof title === 'string') params.title = title;
      if (typeof pic === 'string') params.pic = pic;
      assign(params, options);
      return post('fm.vod', params);
    }
    return post('fm.vod', siteKeyOrPayload || {});
  };
  fm.vodInline = function (payload) { return post('fm.vodInline', payload || {}); };
  fm.ctrl = function (action, value) { return post('fm.ctrl', { action: action, value: value }); };
  fm.stat = function () { return post('fm.stat', {}); };
  // 双约定：fm.search(keyword, options) 与 fm.search({query|keyword})。
  fm.search = function (query, options) {
    if (typeof query === 'string') {
      return post('fm.search', assign({ query: query, keyword: query }, options));
    }
    return post('fm.search', query || {});
  };
  fm.history = function () { return post('fm.history', {}); };
  fm.cache = {
    get: function (key) { return post('fm.cache', { op: 'get', key: String(key) }); },
    set: function (key, value) { return post('fm.cache', { op: 'set', key: String(key), value: value }); },
    remove: function (key) { return post('fm.cache', { op: 'remove', key: String(key) }); },
    del: function (key) { return post('fm.cache', { op: 'del', key: String(key) }); }
  };
  fm.device = function () { return post('fm.device', {}); };
  fm.site = function () { return post('fm.site', {}); };
  fm.config = function () { return post('fm.config', {}); };
  fm.openLive = function (payload) { return post('fm.openLive', payload || {}); };
  fm.openKeep = function (payload) { return post('fm.openKeep', payload || {}); };
  fm.openSetting = function () { return post('fm.openSetting', {}); };
  fm.back = function () { return post('fm.back', {}); };
  fm.reload = function () { return post('fm.reload', {}); };
  // 双约定：fm.preloadArtwork(pic, wallPic) 与 fm.preloadArtwork([urls])。
  fm.preloadArtwork = function (first, second) {
    var urls = [];
    function pushUrl(v) {
      if (typeof v === 'string' && v) {
        urls.push(v);
      } else if (Array.isArray(v)) {
        for (var i = 0; i < v.length; i++) pushUrl(v[i]);
      } else if (isObject(v)) {
        pushUrl(v.pic);
        pushUrl(v.wallPic);
        pushUrl(v.url);
      }
    }
    pushUrl(first);
    pushUrl(second);
    return post('fm.preloadArtwork', { urls: urls });
  };
  fm.pan = {
    play: function (payload) { return post('fm.pan.play', payload || {}); },
    check: function (items) {
      if (Array.isArray(items)) return post('fm.pan.check', { items: items });
      return post('fm.pan.check', items || {});
    }
  };
  fm.ext = {
    info: function () { return post('fm.ext.info', {}); },
    log: function (message) { return post('fm.ext.log', { message: String(message || '') }); },
    toast: function (message) { return post('fm.ext.toast', { message: String(message || '') }); }
  };
  fm.ui = {
    setChrome: function (options) { return post('fm.ui.setChrome', options || {}); },
    restoreChrome: function () { return post('fm.ui.restoreChrome', {}); },
    getViewport: function () { return post('fm.ui.getViewport', {}); }
  };
  window.fm = fm;
  window.GM_xmlhttpRequest = function (details) {
    details = details || {};
    var opts = {
      url: details.url || '',
      method: details.method || 'GET',
      headers: details.headers || {},
      timeout: details.timeout || 0
    };
    if (details.data !== undefined) opts.body = details.data;
    if (details.responseType) opts.responseType = details.responseType;
    if (details.anonymous) opts.credentials = 'omit';
    return post('fm.req', opts).then(function (res) {
      if (typeof details.onload === 'function') {
        var headersText = '';
        var headers = res.headers || {};
        Object.keys(headers).forEach(function (k) { headersText += k + ': ' + headers[k] + '\r\n'; });
        details.onload({
          status: res.status,
          statusText: '',
          responseHeaders: headersText,
          response: res.body,
          responseText: typeof res.body === 'string' ? res.body : JSON.stringify(res.body),
          finalUrl: res.url
        });
      }
      return res;
    }).catch(function (err) {
      if (typeof details.onerror === 'function') details.onerror(err);
      throw err;
    });
  };
  window.GM_getValue = function (key, defaultValue) {
    return fm.cache.get(key).then(function (v) { return (v === null || v === undefined) ? defaultValue : v; });
  };
  window.GM_setValue = function (key, value) { return fm.cache.set(key, value); };
  window.GM_deleteValue = function (key) { return fm.cache.remove(key); };
  window.GM_log = function (message) { return fm.ext.log(message); };
  try {
    document.documentElement.style.setProperty('--moyi-fm-ready', '1');
  } catch (e) {}
  try {
    var siteInfo = window.__moyiSiteInfo || {};
    document.dispatchEvent(new CustomEvent('fmsdk', { detail: { version: 1, siteKey: siteInfo.siteKey || '', siteName: siteInfo.siteName || '' } }));
  } catch (e) {}
})();
// SHIM_END
''';
