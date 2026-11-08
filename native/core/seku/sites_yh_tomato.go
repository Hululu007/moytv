package seku

// ---- 番茄 tomato (yh_tomato) — 正式判: 本模块不是小说阅读器 ----
//
// 判结论 (jadx 全量深读, 见本文件末尾「正式判」节):
//   type 41 的 TomatoActivity 只有三个 tab: LiveFragment (直播间列表,
//   唯一有网络逻辑的页) + HomeFragment 与 PapaFragment (两空壳, 仅
//   layout、无任何请求)。模块内无书名/章节/书架/搜索等任何阅读类
//   bean 与接口, 所谓「mituyuedu 阅读系」是旧报告的推断错误:
//   h6.b f8238b0 (https://mituyuedu.app) 实际由 type 37 的 H5Activity
//   (纯 WebView 入口) 使用, 与 tomato 模块无关; down.tsfsb.com 也
//   不是小说站, 而是直播封面的相对路径前缀 (见下)。
//   故本移植按模块真实形态产件: 直播间目录 (muweifeng tl 直播 API),
//   不产任何小说内容, 也不把空壳两 tab 伪造成分类。
//
// 配方 (p5 包 + tomato bean, 逐行抄):
//   POST https://api.muweifeng.cn/tl/index/liveList
//     body JSON {"branchChannelId":"001_null","pageNumber":<页>,
//       "pageSize":20}, Content-Type: application/json; charset=utf-8
//     (LiveFragment.j 实证)。
//   拦截器 p5.b (LiveInterceptor) 逐项加头:
//     deviceType=android, appId=1, appKey=016c6dd0-0531-4c7f-a531-
//       52b76f0d366c, sdkVersion=3.6.0, osVersion=9.0.1,
//       deviceName=HuaWei, deviceId=32e7984f227cd362,
//       openId=67840436, userId=1050b665-e6d6-412c-8f64-8980031f1efe,
//       token=<APK 内置串, 见 yhTomToken, 注意其中 %2F/%2B 为串内原样
//       字符>, timeStampStr=<当前 unix 秒>,
//       randomStr=<16 字符, 字符集见 yhTomRandChars, 原串含拼写
//       变形 (abcdefghigklmnopk...), 逐字复刻>。
//     注: 以上均为 APK 内置的应用级固定值 (与 cucumber 的 x-auth-key
//     / HG_TOKEN 同类), 非用户个人凭据; 服务端以此识别 App 身份。
//   签名拦截器 p5.e (SignRequestInterceptor):
//     取 body JSON 字段 + 头里的 timeStampStr/randomStr/deviceId,
//     按键名字典序 (Java String.compareTo) 排序, 拼
//       "k=v&k=v..." (跳过 pageSize 与 pageNumber 两个键, 跳过空值),
//     删末尾 "&", 整体转大写后前加 "8zy8nbs9lyddx02slcz8ypmwcr2tlu72_",
//     MD5 后转小写 hex, 置于头 sign。POST 分支直接取 body JSON;
//     GET/PUT 分支取 query (本移植只用 POST)。
//   响应 {code, msg, data:{key, data}} 的解密 (TomatoLiveBase):
//     ① key 字段 Base64 解码 → 以内嵌 RSA 私钥
//        (ENCRYPT_FILE_KEY, PKCS8, 本文件 yhTomRSAKeyB64)
//        RSA/ECB/PKCS1Padding 解密 → 3DES 密钥串 (utf-8)。
//        getJsonData 先把 ENCRYPT_FILE_KEY 按 "\n" 切分并跳过以 '-'
//        开头的行 (PEM 护甲处理; 实际串无护甲, 切分无影响)。
//     ② data 字段 Base64 解码 → 3DES (DESede/CBC/PKCS5Padding,
//        IV="01234567") 解密 → LiveList JSON。
//     ③ o5.a 回调: Gson 解析为 LiveList, 交 RoomAdapter 展示。
//   LiveList 字段: {dataList:[{live:{liveId, topic, nickname,
//     liveCoverUrl, pullStreamUrl, pullStreamUrlH265,
//     lowDefinitionPullStreamUrl, lowDefinitionPullStreamUrlH265,
//     avatar, tag, ticketPrice, chargeType, liveStatus, onlineUserCount,
//     ...}, type}], pageNumber, pageSize, totalPageCount,
//     totalRowsCount}。
//   封面: LiveEntity.getLiveCoverUrl() — 为空或已以 http 开头时原样,
//     否则前补 "http://down.tsfsb.com/" (此即旧报告唯一的 tsfsb 线索)。
//   播放: getDefPullStreamUrlStr() = pullStreamUrl 按 "," 切分后首项;
//     RoomAdapter 点击后交 hgl 的 LiveActivity 直播该地址 (直链免解析)。
// 分类: 仅 "live" 直播一类 (App 仅 LiveFragment 有内容; 另两 tab
//   为空壳, 不造分类)。
// 付费口径: 直播间含 ticketPrice/chargeType 字段; 本移植过滤
//   ticketPrice>0 的间 (门票间不解析), 免费间直出拉流地址。
// 搜索: App 无搜索接口; 本移植 Search 以前 3 页列表做
//   topic/nickname 包含过滤并去重, 头注说明。
//
// 验证状态 (2026-10-24, 施工沙箱):
//   api.muweifeng.cn 本机 DNS 落入 198.18.79.177 假 IP, POST 直连
//   超时 (000), 故活体腿标「出口未验」。但密码链已做离线闭环自证:
//   冒烟测试用内嵌 RSA 私钥推导公钥, 加密一段 3DES 密钥与一段
//   LiveList JSON, 再走本文件同一解密函数还原并比对原文 (见
//   go_build_yh_tomato 测试), 证明 Go 实现与 Java 逻辑一致;
//   签名函数亦以固定输入比对 Java 伪代码手工算值 (见测试)。
//   待可用出口时按指南逐腿冒烟补验, 不把出口问题写成站已死。

import (
	"bytes"
	"crypto/cipher"
	"crypto/des"
	"crypto/md5"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"sort"
	"strconv"
	"strings"
	"time"
)

const yhTomBase = "https://api.muweifeng.cn"
const yhTomUA = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
const yhTomCoverPrefix = "http://down.tsfsb.com/"
const yhTomSignPrefix = "8zy8nbs9lyddx02slcz8ypmwcr2tlu72_"
const yhTomRandChars = "abcdefghigklmnopkrstuvwxyzABCDEFGHIGKLMNOPQRSTUVWXYZ0123456789"

// yhTomToken is the APK-baked app-level token (p5.b), verbatim.
const yhTomToken = "uU7cVKO0pibHC0M1%2FOO9gYCuhmjMplqfEJXyx%2FLj5UTcTCuhsddB2BfY3EuRF6yUNtYIdUXzXcLnKUs8XMAEVXTpjVYxwwWxJTgnNhAcHo2BVBUSttaJpCFO%2Bmy38CwN"

// yhTomRSAKeyB64 is TomatoLiveBase.DataEntity.ENCRYPT_FILE_KEY, decoded
// from ad.r.o() (PKCS8 DER, base64).
const yhTomRSAKeyB64 = "MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGBAJ4BUmnAVmr+0JE7zL195q1QIg1NAW/zln54MjEM6qv45OpTB/jp2zRdw9i4kNPk/IjrOPYPh4dv4+YgYWQkVs0vzVnzuse9rbfoEKDFbze9pyo3EfLnrSUhe3dJp9BWwnq105/zFPkgbx7Qv5T25CMbLTfD0cFHvOAN/HEN/l0HAgMBAAECgYBnFse1dacsgfqEd3a6v5UsyNaexPpGF7C97SAaPqox798zP185OSMrBG5OTQU5KvLVRltQt4seg5M2xzOjyc3TY4/XGZIQtRA35Sovx/s+NvSy6VD+L5SEJ4r8/SXR8mXKJfxKVg8jNOcWiRR4VuQmIozzPEFqZH9qIVJcVjWt0QJBAONHlIRN4OVFzsC3hhc1yv2vYZzzjXcTw8np9wlx1Qjup3rzVhbsAd1KXqpFCTZYlqSfrudDSwQCEXaFyu32uukCQQCx+LyJOoNbnMbPSkZOoQkQfPjgHqy0yAhqiNKT7ciIVyREFmpbB1Q9ptQWDmMwEBb2ksTBNCrgUOX/IE5KsYJvAkEA3Wz6Y5+gEJ7fHGBwUiKFXnxEZG3gD/gAkrHPjLMLMwWXw7BY2kIaWua+rbJOlFTghwhPlV25MvF04/zbRNVRKQJAE5Lv6Yft+p17oEDjCrLbdFzKYpv9EsUNZ+o0fuCgNZ6f9n0gpXJg6Yb3vJVIg3jBjc0Gptk9/f3nze+XrM9pMQJAQ2EroFmPUTuv86Ghwdjnh0z4DnJkr60a6ccoNiqNZpmTAND6og99djzJqGWFHGDGS/JLfbiVdafzj6QZ5TQBzQ=="

func yhTomHeaders() map[string]string {
	return map[string]string{
		"User-Agent":   yhTomUA,
		"Content-Type": "application/json; charset=utf-8",
		"Accept":       "application/json, text/plain, */*",
	}
}

func yhTomRandStr() string {
	var sb strings.Builder
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		for i := range buf {
			buf[i] = byte(time.Now().UnixNano() >> uint(8*(i%8)))
		}
	}
	for _, b := range buf {
		sb.WriteByte(yhTomRandChars[int(b)%len(yhTomRandChars)])
	}
	return sb.String()
}

// yhTomSign replicates p5.e.c(): sorted "k=v&..." (pageSize/pageNumber
// skipped, nil skipped), trailing "&" dropped, uppercased, prefixed,
// MD5 hex (lowercase).
func yhTomSign(fields map[string]string, headers map[string]string) string {
	merged := map[string]string{}
	for k, v := range fields {
		merged[k] = v
	}
	for _, k := range []string{"timeStampStr", "randomStr", "deviceId"} {
		if v, ok := headers[k]; ok {
			merged[k] = v
		}
	}
	keys := []string{}
	for k := range merged {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var sb strings.Builder
	for _, k := range keys {
		if k == "pageSize" || k == "pageNumber" {
			continue
		}
		v := merged[k]
		if v == "" {
			continue
		}
		sb.WriteString(k)
		sb.WriteString("=")
		sb.WriteString(v)
		sb.WriteString("&")
	}
	s := sb.String()
	if strings.HasSuffix(s, "&") {
		s = s[:len(s)-1]
	}
	sum := md5.Sum([]byte(yhTomSignPrefix + strings.ToUpper(s)))
	return hex.EncodeToString(sum[:])
}

func yhTomRSAPrivate() (*rsa.PrivateKey, error) {
	der, err := base64.StdEncoding.DecodeString(yhTomRSAKeyB64)
	if err != nil {
		return nil, fmt.Errorf("yh_tomato rsa key b64: %v", err)
	}
	key, err := x509.ParsePKCS8PrivateKey(der)
	if err != nil {
		// Fallback: PKCS1 form.
		if k2, err2 := x509.ParsePKCS1PrivateKey(der); err2 == nil {
			return k2, nil
		}
		return nil, fmt.Errorf("yh_tomato rsa key parse: %v", err)
	}
	priv, ok := key.(*rsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("yh_tomato rsa key: not RSA")
	}
	return priv, nil
}

// yhTomDecrypt replicates TomatoLiveBase: RSA-decrypt key, then
// 3DES-CBC/PKCS5 (IV "01234567") decrypt data.
func yhTomDecrypt(keyB64, dataB64 string) ([]byte, error) {
	priv, err := yhTomRSAPrivate()
	if err != nil {
		return nil, err
	}
	encKey, err := base64.StdEncoding.DecodeString(strings.TrimSpace(keyB64))
	if err != nil {
		return nil, fmt.Errorf("yh_tomato key b64: %v", err)
	}
	desKey, err := rsa.DecryptPKCS1v15(rand.Reader, priv, encKey)
	if err != nil {
		return nil, fmt.Errorf("yh_tomato rsa decrypt: %v", err)
	}
	enc, err := base64.StdEncoding.DecodeString(dataB64)
	if err != nil {
		return nil, fmt.Errorf("yh_tomato data b64: %v", err)
	}
	block, err := des.NewTripleDESCipher(desKey)
	if err != nil {
		return nil, fmt.Errorf("yh_tomato 3des: %v", err)
	}
	if len(enc) == 0 || len(enc)%block.BlockSize() != 0 {
		return nil, fmt.Errorf("yh_tomato 3des: bad ciphertext length %d", len(enc))
	}
	// 3DES key from the server is 24 bytes; if a 16-byte two-key form
	// ever arrives, expand K1||K2 -> K1||K2||K1 (standard 2-key 3DES).
	if len(desKey) == 16 {
		desKey = append(append([]byte{}, desKey...), desKey[:8]...)
		block, err = des.NewTripleDESCipher(desKey)
		if err != nil {
			return nil, fmt.Errorf("yh_tomato 3des: %v", err)
		}
	}
	out := make([]byte, len(enc))
	cipher.NewCBCDecrypter(block, []byte("01234567")).CryptBlocks(out, enc)
	if len(out) == 0 {
		return nil, fmt.Errorf("yh_tomato 3des: empty plaintext")
	}
	pad := int(out[len(out)-1])
	if pad < 1 || pad > block.BlockSize() || pad > len(out) {
		return nil, fmt.Errorf("yh_tomato 3des: bad padding")
	}
	return out[:len(out)-pad], nil
}

func yhTomLiveList(page int) (map[string]interface{}, error) {
	if page < 1 {
		page = 1
	}
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	rs := yhTomRandStr()
	headers := yhTomHeaders()
	headers["deviceType"] = "android"
	headers["appId"] = "1"
	headers["appKey"] = "016c6dd0-0531-4c7f-a531-52b76f0d366c"
	headers["sdkVersion"] = "3.6.0"
	headers["osVersion"] = "9.0.1"
	headers["deviceName"] = "HuaWei"
	headers["timeStampStr"] = ts
	headers["randomStr"] = rs
	headers["deviceId"] = "32e7984f227cd362"
	headers["openId"] = "67840436"
	headers["token"] = yhTomToken
	headers["userId"] = "1050b665-e6d6-412c-8f64-8980031f1efe"
	fields := map[string]string{
		"branchChannelId": "001_null",
		"pageNumber":      strconv.Itoa(page),
		"pageSize":        "20",
	}
	headers["sign"] = yhTomSign(fields, headers)
	body, _ := json.Marshal(map[string]interface{}{
		"branchChannelId": "001_null",
		"pageNumber":      page,
		"pageSize":        20,
	})
	b, code, _, err := httpDo("POST", yhTomBase+"/tl/index/liveList", bytes.NewReader(body), headers)
	if err != nil {
		return nil, err
	}
	if code != 200 {
		return nil, fmt.Errorf("yh_tomato http %d", code)
	}
	var env map[string]interface{}
	if err := json.Unmarshal(b, &env); err != nil {
		return nil, fmt.Errorf("yh_tomato parse: %v", err)
	}
	data := yhMap(env["data"])
	if data == nil {
		return nil, fmt.Errorf("yh_tomato: empty data envelope")
	}
	plain, err := yhTomDecrypt(g5StrVal(data["key"]), g5StrVal(data["data"]))
	if err != nil {
		return nil, err
	}
	var list map[string]interface{}
	if err := json.Unmarshal(plain, &list); err != nil {
		return nil, fmt.Errorf("yh_tomato liveList parse: %v", err)
	}
	return list, nil
}

func yhTomCover(raw string) string {
	if raw == "" || strings.HasPrefix(raw, "http") {
		return raw
	}
	return yhTomCoverPrefix + raw
}

func yhTomCard(slot string, ent map[string]interface{}) (map[string]interface{}, bool) {
	live := yhMap(ent["live"])
	if live == nil {
		return nil, false
	}
	id := g5StrVal(live["liveId"])
	title := g5StrVal(live["topic"])
	if id == "" {
		return nil, false
	}
	if title == "" {
		title = g5StrVal(live["nickname"])
	}
	if title == "" {
		title = "直播间" + id
	}
	remark := g5StrVal(live["nickname"])
	if n, ok := g5MapInt(live, "onlineUserCount"); ok && n > 0 {
		if remark != "" {
			remark += " · "
		}
		remark += fmt.Sprintf("%d人在看", n)
	}
	if s := g5StrVal(live["liveStatus"]); s != "" {
		if remark != "" {
			remark += " · "
		}
		remark += s
	}
	desc := g5StrVal(live["tag"])
	return makeDrama(slot, id, title, yhTomCover(g5StrVal(live["liveCoverUrl"])), remark, "直播", desc), true
}

func yhTomRooms(slot string, list map[string]interface{}) []interface{} {
	out := []interface{}{}
	seen := map[string]bool{}
	for _, e := range yhArr(list["dataList"]) {
		ent := yhMap(e)
		if ent == nil {
			continue
		}
		live := yhMap(ent["live"])
		if live == nil {
			continue
		}
		// 门票间不解析: ticketPrice>0 即付费间。
		if n, ok := live["ticketPrice"].(float64); ok && n > 0 {
			continue
		}
		if s := g5StrVal(live["ticketPrice"]); s != "" && s != "0" {
			continue
		}
		if c, ok := yhTomCard(slot, ent); ok {
			id := g5StrVal(live["liveId"])
			if !seen[id] {
				seen[id] = true
				out = append(out, c)
			}
		}
	}
	return out
}

func yhTomCategories(slot string) []interface{} {
	return []interface{}{
		categoryObj("live", "直播"),
	}
}

func yhTomCatalog(slot, category string, page int) ([]interface{}, int, bool, error) {
	if page < 1 {
		page = 1
	}
	list, err := yhTomLiveList(page)
	if err != nil {
		return nil, 0, false, err
	}
	items := yhTomRooms(slot, list)
	total := 0
	if n, ok := g5MapInt(list, "totalRowsCount"); ok {
		total = n
	}
	hasMore := false
	if n, ok := g5MapInt(list, "totalPageCount"); ok {
		hasMore = page < n
	} else {
		hasMore = len(items) > 0
	}
	return items, total, hasMore, nil
}

func yhTomFindRoom(slot, liveID string) (map[string]interface{}, error) {
	if st := getStore(slot).findDrama(liveID); st != nil {
		// Store only keeps card fields; still need pull URL, so scan.
		_ = st
	}
	for p := 1; p <= 5; p++ {
		list, err := yhTomLiveList(p)
		if err != nil {
			return nil, err
		}
		for _, e := range yhArr(list["dataList"]) {
			ent := yhMap(e)
			if ent == nil {
				continue
			}
			live := yhMap(ent["live"])
			if live != nil && g5StrVal(live["liveId"]) == liveID {
				return live, nil
			}
		}
		if n, ok := g5MapInt(list, "totalPageCount"); ok && p >= n {
			break
		}
	}
	return nil, fmt.Errorf("yh_tomato: room %s not found in first pages", liveID)
}

func yhTomDetail(slot, rawID string) (map[string]interface{}, error) {
	title := "直播间" + rawID
	cover := ""
	remark := ""
	desc := ""
	if st := getStore(slot).findDrama(rawID); st != nil {
		if s := g5StrVal(st["title"]); s != "" {
			title = s
		}
		cover = g5StrVal(st["cover"])
		remark = g5StrVal(st["remark"])
		desc = g5StrVal(st["desc"])
	}
	live, err := yhTomFindRoom(slot, rawID)
	if err != nil {
		// Room may have gone offline; still return the card shell.
		d := makeDrama(slot, rawID, title, cover, remark, "直播", desc)
		g5SetChapters(d, slot, rawID, []string{rawID}, []string{"直播"})
		return d, nil
	}
	if s := g5StrVal(live["topic"]); s != "" {
		title = s
	}
	cover = yhTomCover(g5StrVal(live["liveCoverUrl"]))
	remark = g5StrVal(live["nickname"])
	desc = g5StrVal(live["tag"])
	d := makeDrama(slot, rawID, title, cover, remark, "直播", desc)
	g5SetChapters(d, slot, rawID, []string{rawID}, []string{"直播"})
	return d, nil
}

func yhTomResolve(slot, rawID string) (map[string]interface{}, error) {
	liveID := rawID
	if i := strings.Index(rawID, "$"); i >= 0 {
		liveID = rawID[i+1:]
	}
	live, err := yhTomFindRoom(slot, liveID)
	if err != nil {
		return nil, err
	}
	if n, ok := live["ticketPrice"].(float64); ok && n > 0 {
		return nil, fmt.Errorf("yh_tomato: paid room is not resolved")
	}
	if s := g5StrVal(live["ticketPrice"]); s != "" && s != "0" {
		return nil, fmt.Errorf("yh_tomato: paid room is not resolved")
	}
	pull := g5StrVal(live["pullStreamUrl"])
	first := pull
	if parts := strings.Split(pull, ","); len(parts) > 0 {
		first = strings.TrimSpace(parts[0])
	}
	if first == "" {
		return nil, fmt.Errorf("yh_tomato: no pull stream url for %s", liveID)
	}
	format := "flv"
	protocol := ""
	if strings.Contains(first, ".m3u8") {
		format, protocol = "m3u8", "hls"
	} else if strings.Contains(first, ".mp4") {
		format = "mp4"
	}
	return playResult(first, slot, rawID, yhTomUA, yhTomBase+"/", format, protocol), nil
}

func yhTomSearch(slot, kw string) ([]interface{}, error) {
	kw = strings.TrimSpace(kw)
	if kw == "" {
		return nil, fmt.Errorf("yh_tomato: empty keyword")
	}
	lower := strings.ToLower(kw)
	out := []interface{}{}
	seen := map[string]bool{}
	for p := 1; p <= 3; p++ {
		list, err := yhTomLiveList(p)
		if err != nil {
			break
		}
		for _, it := range yhTomRooms(slot, list) {
			if im, ok := it.(map[string]interface{}); ok {
				hay := strings.ToLower(g5StrVal(im["title"]) + " " + g5StrVal(im["remark"]))
				if !strings.Contains(hay, lower) {
					continue
				}
				id := g5StrVal(im["vod_id"])
				if seen[id] {
					continue
				}
				seen[id] = true
			}
			out = append(out, it)
		}
		if n, ok := g5MapInt(list, "totalPageCount"); ok && p >= n {
			break
		}
	}
	return out, nil
}

// yhTomCoverFetch: 直载封面字节 (tsfsb CDN), 只做明文魔数门禁。
func yhTomCoverFetch(u string) ([]byte, error) {
	b, code, _, err := httpGet(u, yhTomHeaders())
	if err != nil {
		return nil, err
	}
	if code != 200 {
		return nil, fmt.Errorf("yh_tomato cover http %d", code)
	}
	if yhTomIsImage(b) {
		return b, nil
	}
	return nil, fmt.Errorf("yh_tomato cover: not an image (first bytes % x)", yhTomHead(b))
}

func yhTomIsImage(b []byte) bool {
	if len(b) >= 2 && b[0] == 0xFF && b[1] == 0xD8 {
		return true
	}
	if len(b) >= 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 {
		return true
	}
	if len(b) >= 12 && string(b[0:4]) == "RIFF" && string(b[8:12]) == "WEBP" {
		return true
	}
	if len(b) >= 3 && b[0] == 'G' && b[1] == 'I' && b[2] == 'F' {
		return true
	}
	return false
}

func yhTomHead(b []byte) []byte {
	if len(b) > 8 {
		return b[:8]
	}
	return b
}

// yhTomPubModulus exposes the RSA public modulus for the smoke test
// (round-trip proof of the decryption chain).
func yhTomPubModulus() *big.Int {
	priv, err := yhTomRSAPrivate()
	if err != nil {
		return nil
	}
	return priv.PublicKey.N
}
