/// HTML 宿主注入的 fm 桥垫片：页面里的 `fm.*` / `GM_*` 入口。
///
/// ES2017 写法（不用可选链/空值合并），只装在顶层帧；单文件站由
/// 回环服务以 script 标签注入，原站增强站由宿主页面在加载完成后
/// runJavaScript 注入。垫片只负责把调用发给原生通道
/// `MoyiHtmlNative`，不做任何业务判断。
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
  var fm = {};
  fm.req = function (options) { return post('fm.req', options || {}); };
  fm.res = function (options) { return post('fm.res', options || {}); };
  fm.play = function (payload) { return post('fm.play', payload || {}); };
  fm.vod = function (payload) { return post('fm.vod', payload || {}); };
  fm.vodInline = function (payload) { return post('fm.vodInline', payload || {}); };
  fm.ctrl = function (action, value) { return post('fm.ctrl', { action: action, value: value }); };
  fm.stat = function () { return post('fm.stat', {}); };
  fm.search = function (query) {
    if (typeof query === 'string') return post('fm.search', { query: query });
    return post('fm.search', query || {});
  };
  fm.history = function () { return post('fm.history', {}); };
  fm.cache = {
    get: function (key) { return post('fm.cache', { op: 'get', key: String(key) }); },
    set: function (key, value) { return post('fm.cache', { op: 'set', key: String(key), value: value }); },
    remove: function (key) { return post('fm.cache', { op: 'remove', key: String(key) }); }
  };
  fm.device = function () { return post('fm.device', {}); };
  fm.site = function () { return post('fm.site', {}); };
  fm.config = function () { return post('fm.config', {}); };
  fm.openLive = function (payload) { return post('fm.openLive', payload || {}); };
  fm.openKeep = function (payload) { return post('fm.openKeep', payload || {}); };
  fm.openSetting = function () { return post('fm.openSetting', {}); };
  fm.back = function () { return post('fm.back', {}); };
  fm.reload = function () { return post('fm.reload', {}); };
  fm.preloadArtwork = function (urls) { return post('fm.preloadArtwork', { urls: urls || [] }); };
  fm.pan = {
    play: function (payload) { return post('fm.pan.play', payload || {}); },
    check: function (payload) { return post('fm.pan.check', payload || {}); }
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
