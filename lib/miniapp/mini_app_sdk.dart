class MiniAppSdkScript {
  static const String channelName = 'MoyiMiniApp';

  static const String script = r'''
(function () {
  'use strict';
  if (window.ant) return;
  var seq = 0;
  var pending = {};
  var listeners = {};
  var launchOptions = null;

  function invoke(api, params) {
    return new Promise(function (resolve, reject) {
      var callId = ++seq;
      pending[callId] = { resolve: resolve, reject: reject };
      try {
        window.MoyiMiniApp.postMessage(JSON.stringify({
          callId: callId, api: api, params: params || {}
        }));
      } catch (e) {
        delete pending[callId];
        reject(e);
      }
    });
  }

  window.__moyiResolve = function (payload) {
    if (!payload || payload.callId === undefined) return;
    var entry = pending[payload.callId];
    if (!entry) return;
    delete pending[payload.callId];
    if (payload.ok) {
      entry.resolve(payload.data === undefined ? null : payload.data);
    } else {
      var error = new Error(payload.message || 'JSAPI 调用失败');
      error.code = payload.code || 'UNKNOWN';
      error.api = payload.api;
      entry.reject(error);
    }
  };

  window.__moyiEmit = function (event, data) {
    if (event === 'miniApp.open') launchOptions = data || null;
    var list = (listeners[event] || []).slice();
    for (var i = 0; i < list.length; i++) {
      try { list[i](data); } catch (e) {}
    }
  };

  function on(event, handler) {
    if (typeof handler !== 'function') return function () {};
    (listeners[event] = listeners[event] || []).push(handler);
    return function () { off(event, handler); };
  }

  function off(event, handler) {
    var list = listeners[event];
    if (!list) return;
    if (!handler) { delete listeners[event]; return; }
    var index = list.indexOf(handler);
    if (index >= 0) list.splice(index, 1);
  }

  function once(event, handler) {
    var dispose = on(event, function (data) { dispose(); handler(data); });
    return dispose;
  }

  function getJSON(key, fallback) {
    return invoke('storage.get', { key: key }).then(function (value) {
      if (value === null || value === undefined) return fallback;
      try { return JSON.parse(value); } catch (e) { return fallback; }
    });
  }

  function setJSON(key, value) {
    return invoke('storage.set', {
      key: key, value: JSON.stringify(value === undefined ? null : value)
    });
  }

  window.ant = {
    // 宿主 SDK 版本：4 = source.* + player.open（含 parse/jx 线路的
    // 嗅探解析）。影视库按 ant.version >= 4 才放行解析线路。
    version: 4,
    invoke: invoke,
    on: on,
    off: off,
    once: once,
    env: {
      getSystemInfo: function () { return invoke('env.getSystemInfo', {}); }
    },
    log: function (message) {
      return invoke('log', { message: String(message) });
    },
    request: function (opts) { return invoke('request', opts || {}); },
    requestJson: function (opts) {
      return invoke('request', opts || {}).then(function (res) {
        try { return JSON.parse(res.data); } catch (e) { return res.data; }
      });
    },
    resolveService: function (url) {
      return invoke('resolveService', { url: url });
    },
    storage: {
      get: function (key) { return invoke('storage.get', { key: key }); },
      set: function (key, value) {
        return invoke('storage.set', { key: key, value: String(value) });
      },
      remove: function (key) { return invoke('storage.remove', { key: key }); },
      clear: function () { return invoke('storage.clear', {}); },
      keys: function () { return invoke('storage.keys', {}); },
      getJSON: getJSON,
      setJSON: setJSON
    },
    file: {
      write: function (path, content) {
        return invoke('file.write', { path: path, content: content });
      },
      read: function (path) { return invoke('file.read', { path: path }); },
      stat: function (path) { return invoke('file.stat', { path: path }); },
      list: function (path) { return invoke('file.list', { path: path || '' }); },
      mkdir: function (path) { return invoke('file.mkdir', { path: path }); },
      rename: function (from, to) {
        return invoke('file.rename', { from: from, to: to });
      },
      delete: function (path) { return invoke('file.delete', { path: path }); }
    },
    clipboard: {
      get: function () { return invoke('clipboard.get', {}); },
      set: function (text) { return invoke('clipboard.set', { text: text }); }
    },
    ui: {
      toast: function (message) {
        return invoke('ui.toast', { message: String(message) });
      },
      loading: function (message) {
        return invoke('ui.loading', { message: message || '' });
      },
      hideLoading: function () { return invoke('ui.hideLoading', {}); },
      confirm: function (opts) { return invoke('ui.confirm', opts || {}); },
      actionSheet: function (items) {
        return invoke('ui.actionSheet', { items: items || [] });
      }
    },
    navigateTo: function (path) {
      return invoke('navigateTo', { path: path });
    },
    redirectTo: function (path) {
      return invoke('redirectTo', { path: path });
    },
    navigateBack: function () { return invoke('navigateBack', {}); },
    exitMiniApp: function () { return invoke('exitMiniApp', {}); },
    miniApp: {
      open: function (opts) { return invoke('miniApp.open', opts || {}); },
      getLaunchOptions: function () {
        return invoke('miniApp.getLaunchOptions', {});
      }
    },
    player: {
      open: function (params) { return invoke('player.open', params || {}); },
      getState: function () { return invoke('player.getState', {}); },
      onStateChange: function (handler) {
        return on('player.stateChange', handler);
      },
      onClose: function (handler) { return on('player.close', handler); }
    },
    source: {
      list: function () { return invoke('source.list', {}); },
      home: function (siteKey) { return invoke('source.home', { siteKey: siteKey }); },
      category: function (opts) { return invoke('source.category', opts || {}); },
      detail: function (opts) { return invoke('source.detail', opts || {}); },
      play: function (opts) { return invoke('source.play', opts || {}); },
      search: function (opts) { return invoke('source.search', opts || {}); }
    },
    python: {
      call: function (method) {
        var args = Array.prototype.slice.call(arguments, 1);
        return invoke('python.call', { method: method, args: args });
      }
    },
    tv: {
      onKey: function (handler) { return on('keydown', handler); }
    },
    onShow: function (handler) { return on('app.show', handler); },
    onHide: function (handler) { return on('app.hide', handler); },
    getLaunchOptions: function () { return launchOptions; }
  };
})();
''';
}
