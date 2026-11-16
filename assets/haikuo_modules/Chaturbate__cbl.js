js:(function () {
// ==== Chaturbate 数据引擎 v1（模块化单例，path: cbl） ====
// 站点：https://www.chaturbate.lat/（Chaturbate 镜像域，官方前端+API）
// 房源：GET /api/ts/roomlist/room-list/（genders/limit/offset/keywords/regions）
// 取流：GET /api/chatvideocontext/{room}/ -> hls_source（镜像域直出，匿名可看 public 房）
//  • type=live；4 性别分类 + 6 地区筛选（标准 UILib navs/filters：sd_cls/sd_page/sd_filter）
//  • 卡片用真实房间页 URL（原生 200），经顶层 detail_find_rule 进详情（不用 @rule 跳模块）
//  • 详情在页面上下文取 hls，选集=最终 m3u8 纯字符串 + #isVideo=true#
var X = {};
// ---------- 清晰度（data: URI 方案，不走本地代理） ----------
// master 音视频分离：分档 URL 纯视频无声。把"单档视频+其音频组"过滤成新的
// master 文本（URI 全转绝对），base64 后做成 data: URI 选集，播放器解析后
// 直接从 CDN 拉音视频。失败回退 master 原地址。
X._masterText = '';
X._absUrl = function (base, rel) {
  if (/^https?:\/\//i.test(rel)) return rel;
  var m = /^(https?:\/\/[^\/]+)/.exec(base), origin = m ? m[1] : '';
  if (rel.charAt(0) === '/') return origin + rel;
  var b = String(base).split('?')[0], s = b.lastIndexOf('/');
  return b.substring(0, s + 1) + rel;
};
X._b64encode = function (str) {
  var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var bytes = [], i, c;
  for (i = 0; i < str.length; i++) {
    c = str.charCodeAt(i);
    if (c < 128) bytes.push(c);
    else if (c < 2048) bytes.push(192 | (c >> 6), 128 | (c & 63));
    else bytes.push(224 | (c >> 12), 128 | ((c >> 6) & 63), 128 | (c & 63));
  }
  var out = '';
  for (i = 0; i < bytes.length; i += 3) {
    var b1 = bytes[i], b2 = i + 1 < bytes.length ? bytes[i + 1] : 0, b3 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    var n = (b1 << 16) | (b2 << 8) | b3;
    out += chars[(n >> 18) & 63] + chars[(n >> 12) & 63]
      + (i + 1 < bytes.length ? chars[(n >> 6) & 63] : '=')
      + (i + 2 < bytes.length ? chars[n & 63] : '=');
  }
  return out;
};
X._qualities = function (masterUrl) {
  var out = [];
  try {
    var txt = fetch(masterUrl, { headers: { 'User-Agent': X.UA, 'Referer': X.HOST + '/' }, timeout: 60000 });
    if (!txt || txt === 'error') return out;
    txt = String(txt);
    X._masterText = txt;
    var re = /#EXT-X-STREAM-INF:([^\r\n]+)\r?\n([^#\r\n][^\r\n]*)/g, m, seen = {};
    while ((m = re.exec(txt)) !== null) {
      var attrs = m[1], uri = m[2].trim();
      if (!uri) continue;
      var bw = 0, res = '';
      var bm = /BANDWIDTH=(\d+)/.exec(attrs); if (bm) bw = parseInt(bm[1], 10) || 0;
      var rm = /RESOLUTION=(\d+)x(\d+)/.exec(attrs); if (rm) res = rm[2] + 'p';
      var fr = /FRAME-RATE=([\d.]+)/.exec(attrs), fps = fr ? Math.round(parseFloat(fr[1])) : 0;
      if (!res) continue;
      var key = res + (fps >= 50 ? '60' : '');
      if (seen[key] && seen[key] >= bw) continue;
      seen[key] = bw;
      out.push({ bw: bw, name: '🔴 ' + res + (fps >= 50 ? '60' : '') });
    }
    out.sort(function (a, b) { return b.bw - a.bw; });
  } catch (e) {}
  return out;
};
X._dataQualityUrl = function (masterUrl, bw) {
  try {
    var txt = X._masterText || '';
    if (!txt) return '';
    var lines = txt.split('\n'), audioGroups = {}, variants = [], i, ln;
    for (i = 0; i < lines.length; i++) {
      ln = lines[i].trim();
      var mm = /^#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="([^"]+)"(.*)$/.exec(ln);
      if (mm) {
        var um = /URI="([^"]+)"/.exec(ln);
        audioGroups[mm[1]] = um ? ln.replace(/URI="[^"]+"/, 'URI="' + X._absUrl(masterUrl, um[1]) + '"') : ln;
      }
      var sm = /^#EXT-X-STREAM-INF:(.*)$/.exec(ln);
      if (sm) {
        var uri = (i + 1 < lines.length) ? lines[i + 1].trim() : '';
        var b = 0, ag = '';
        var bwm = /BANDWIDTH=(\d+)/.exec(sm[1]); if (bwm) b = parseInt(bwm[1], 10) || 0;
        var agm = /AUDIO="([^"]+)"/.exec(sm[1]); if (agm) ag = agm[1];
        variants.push({ bw: b, inf: sm[1], uri: uri, audio: ag });
      }
    }
    var pick = null;
    for (i = 0; i < variants.length; i++) {
      if (variants[i].bw === bw) { pick = variants[i]; break; }
    }
    if (!pick || !pick.uri) return '';
    var out = ['#EXTM3U', '#EXT-X-VERSION:6', '#EXT-X-INDEPENDENT-SEGMENTS'];
    if (pick.audio && audioGroups[pick.audio]) out.push(audioGroups[pick.audio]);
    out.push('#EXT-X-STREAM-INF:' + pick.inf);
    out.push(X._absUrl(masterUrl, pick.uri));
    return 'data:application/vnd.apple.mpegurl;base64,' + X._b64encode(out.join('\n')) + '#isM3u8#';
  } catch (e) { return ''; }
};
X.HOST = 'https://www.chaturbate.lat';
X.UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
X.GENDERS = [
  ['f', '♀ 女性'], ['m', '♂ 男性'], ['c', '💑 情侣'], ['t', '⚧ 跨性别']
];
X.REGIONS = [
  { name: '全部地区', value: '' }, { name: '北美', value: 'NA' }, { name: '欧洲俄罗斯', value: 'ER' },
  { name: '亚洲', value: 'AS' }, { name: '南美', value: 'SA' }, { name: '其他', value: 'O' }
];
// ---------- 房源 ----------
X._rooms = function (params) {
  var q = [];
  for (var k in params) {
    if (params[k] === '' || params[k] === null || params[k] === undefined) continue;
    q.push(encodeURIComponent(k) + '=' + encodeURIComponent(params[k]));
  }
  var url = X.HOST + '/api/ts/roomlist/room-list/?' + q.join('&');
  try {
    var res = fetch(url, {
      headers: {
        'User-Agent': X.UA, 'Accept': 'application/json, text/plain, */*',
        'Referer': X.HOST + '/', 'X-Requested-With': 'XMLHttpRequest'
      },
      timeout: 60000
    });
    if (!res || res === 'error') return { rooms: [], total: 0 };
    var d = JSON.parse(String(res));
    return { rooms: d.rooms || [], total: d.total_count || 0 };
  } catch (e) { return { rooms: [], total: 0 }; }
};
X._statusBadge = function (r) {
  var show = String(r.current_show || '').toLowerCase();
  // private/group/ticket 等为付费中；公开列表一般全是 public，逻辑保留
  if (show === 'private' || show === 'group' || show === 'ticket' || show === 'password') return '💰 收费中';
  return '🔴 直播中';
};
X._card = function (r) {
  var username = r.username || '';
  // 标题去 HTML 标签（如 <a href="/tag/…"）
  var subject = String(r.subject || r.room_subject || '').replace(/<[^>]*>/g, '').trim();
  var viewers = parseInt(r.num_users, 10) || 0;
  // 备注尽量短：徽章+人数，避免过长被截断
  var remark = X._statusBadge(r) + (viewers > 0 ? '·' + viewers + '人' : '');
  return {
    title: subject || username,
    pic: r.img || '',
    desc: remark,
    url: X.HOST + '/' + encodeURIComponent(username) + '/#immersiveTheme#'
  };
};
// ---------- 首页/分类 ----------
// 分页：明确的上一页/下一页按钮（sd_page；自动翻页在部分设备上不触发，改回按钮最稳）
X.home = function () {
  var cls = '';
  try { cls = String(getMyVar('sd_cls', '')); } catch (e) {}
  var navs = [];
  for (var i = 0; i < X.GENDERS.length; i++) navs.push({ title: X.GENDERS[i][1], id: X.GENDERS[i][0] });
  if (!cls) {
    var r = X._rooms({ genders: 'f', limit: 21, offset: 0 });
    var items = [];
    for (var j = 0; j < r.rooms.length; j++) items.push(X._card(r.rooms[j]));
    $.require('uil').renderHome({
      search: { placeholder: '搜索主播名（英文）…' },
      navs: navs,
      sections: [{ title: '🔴 正在直播', items: items }]
    });
    return;
  }
  var pg = 1;
  try { pg = parseInt(getMyVar('sd_page', '1'), 10) || 1; } catch (e2) {}
  if (pg < 1) pg = 1;
  var fst = {};
  try { fst = JSON.parse(getVar('sd_filter', '{}')); } catch (e3) {}
  var params = { genders: cls, limit: 21, offset: (pg - 1) * 21 };
  if (fst.region) params.regions = fst.region;
  var r2 = X._rooms(params);
  var items2 = [];
  for (var k = 0; k < r2.rooms.length; k++) items2.push(X._card(r2.rooms[k]));
  $.require('uil').renderHome({
    navs: navs,
    filters: [{ key: 'region', options: X.REGIONS }],
    listItems: items2,
    page: pg,
    hasMore: r2.rooms.length >= 21
  });
};
// ---------- 详情 ----------
X.detail = function () {
  var room = '';
  try {
    var m = /chaturbate\.lat\/([^\/#?]+)/.exec(String(MY_URL));
    if (m) room = decodeURIComponent(m[1]);
  } catch (e) {}
  if (!room) { setError('未获取到主播名'); return; }
  var info = null;
  try {
    var r = X._rooms({ genders: 'f,m,c,t', limit: 30, offset: 0, keywords: room });
    for (var i = 0; i < r.rooms.length; i++) {
      if (String(r.rooms[i].username || '').toLowerCase() === String(room).toLowerCase()) { info = r.rooms[i]; break; }
    }
    if (!info && r.rooms.length) info = r.rooms[0];
  } catch (e2) {}
  var title = room, pic = '', desc = '🔴LIVE', intro = '';
  if (info) {
    title = String(info.subject || info.room_subject || room).trim() || room;
    pic = info.img || '';
    var viewers = parseInt(info.num_users, 10) || 0;
    desc = '🔴LIVE' + (viewers > 0 ? '·' + viewers + '人' : '');
    var parts = [];
    if (info.display_age) parts.push('年龄:' + info.display_age);
    if (info.location) parts.push(info.location);
    if (info.num_followers) parts.push('关注:' + info.num_followers);
    var tags = info.tags || [];
    if (tags.length) intro += '标签：' + tags.slice(0, 15).map(function (t) { return '#' + t; }).join(' ') + '\n';
    if (parts.length) intro += parts.join(' / ');
  }
  var hls = '';
  try {
    var res = fetch(X.HOST + '/api/chatvideocontext/' + encodeURIComponent(room) + '/', {
      headers: {
        'User-Agent': X.UA, 'Accept': 'application/json',
        'Referer': X.HOST + '/' + room + '/', 'X-Requested-With': 'XMLHttpRequest'
      },
      timeout: 60000
    });
    if (res && res !== 'error') {
      var d = JSON.parse(String(res));
      var keys = ['hls_source', 'hlsSource', 'hls_url', 'url', 'source'];
      for (var k = 0; k < keys.length; k++) {
        var u = d[keys[k]];
        if (u && String(u).indexOf('.m3u8') >= 0) { hls = String(u); break; }
      }
    }
  } catch (e3) {}
  var lines = [];
  if (hls) {
    // 各清晰度：data: URI（单档视频+音频组，不过代理），真机确认可播有声音；
    // master 原地址那集播不了，已去掉（data 失败时才回退 master 保底）
    var eps = [];
    var qs = X._qualities(hls);
    for (var q = 0; q < qs.length; q++) {
      var dq = X._dataQualityUrl(hls, qs[q].bw);
      if (dq) eps.push({ name: qs[q].name, url: dq });
    }
    if (!eps.length) eps.push({ name: '🔴 观看直播', url: hls + '#isVideo=true#' });
    lines.push({ name: '直播', episodes: eps });
  } else {
    intro += (intro ? '\n\n' : '') + '（主播当前离线或取流失败）';
  }
  $.require('uil').renderDetail({
    poster: { title: title, desc: desc, pic: pic, url: 'javascript:;' },
    intro: intro || title,
    lines: lines,
    sortable: false
  });
};
// ---------- 搜索 ----------
X.search = function () {
  var kw = '';
  try { kw = String(MY_KEYWORD || getMyVar('keyword', '')); } catch (e) {}
  kw = kw.trim().replace(/^#/, '');
  if (!kw) { $.require('uil').renderSearch({ items: [] }); return; }
  var r = X._rooms({ genders: 'f,m,c,t', limit: 60, offset: 0, keywords: kw });
  var items = [];
  for (var i = 0; i < r.rooms.length; i++) items.push(X._card(r.rooms[i]));
  $.require('uil').renderSearch({ items: items });
};
$.exports = X;
})();
