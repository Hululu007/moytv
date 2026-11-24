package core

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha512"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

var hongguoSpadeDerivationConstants = func() []byte {
	decoded, err := hex.DecodeString("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")
	if err != nil {
		return nil
	}
	return decoded
}()

// hongguoAppMediaBudget：一次 App 取流的总预算，取流梯子（门内设备重试与
// 暂态重试）全部包在里面；预算耗尽即交给网页兜底，不再无尽重试拖住播放页。
// var 供测试收紧预算验证截止行为，生产值不动。
var hongguoAppMediaBudget = 90 * time.Second

// hongguoAppMediaRotationBackoff：轮换重试间的退避：1s、2s、4s 封顶，
// 避免新身份立即重撞同一面限流墙。attempt 为轮换次数（从 1 起）。
// V5 梯子不再用它（暂态退避走上游 200ms 起翻倍、封顶 5s）；
// 番茄 feed 恢复环仍用它，函数与测试保留。
func hongguoAppMediaRotationBackoff(attempt int) time.Duration {
	if attempt < 1 {
		attempt = 1
	}
	backoff := time.Duration(1<<(attempt-1)) * time.Second
	if backoff > 4*time.Second {
		backoff = 4 * time.Second
	}
	return backoff
}

// hongguoSleepContext：可被 ctx 取消的等待；ctx 先取消返回 ctx 的错误。
func hongguoSleepContext(ctx context.Context, wait time.Duration) error {
	if wait <= 0 {
		return nil
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (downloader *Downloader) resolveHongguoAppMedia(ctx context.Context, videoID string) (providerMedia, error) {
	return downloader.resolveHongguoAppMediaWithUpcoming(ctx, videoID, nil)
}

// resolveHongguoAppMediaWithUpcoming：upcoming 为当前集之后的最多 2 个分集 ID，
// V5 门一次取回后进预取缓存；单集调用传 nil 即可。
// 链路形态（梯子）：总预算 + 设备续新 + 取流梯子 anon→v5→model-a→model-c→
// tab-b。旧的三腿轮换环、设备被拒单次重试、海外线重试已随 V5 设计撤掉；
// 空回包不再直接报错——先同门重探、再降级下一门、至多一次身份轮换后重跑
// （见 provider_hongguo_v5_media.go）。
func (downloader *Downloader) resolveHongguoAppMediaWithUpcoming(ctx context.Context, videoID string, upcoming []string) (providerMedia, error) {
	if !hongguoNumericID.MatchString(videoID) {
		return providerMedia{}, errors.New("红果视频 ID 无效")
	}
	// 总预算包住整条 V5 链；预算内耗尽即返回，调用方改走网页兜底。
	// 调用方自己的 ctx 取消同样生效。
	budgetCtx, cancel := context.WithTimeout(ctx, hongguoAppMediaBudget)
	defer cancel()
	ctx = budgetCtx
	if err := downloader.ensureHongguoDevice(ctx, ""); err != nil {
		return providerMedia{}, err
	}
	if downloader.hongguoDeviceLimited() {
		downloader.ensureHongguoDevice(ctx, downloader.hongguoDeviceID())
	}
	return downloader.hongguoV5FetchModel(ctx, videoID, upcoming)
}

// hongguoPlayerBizParam：JS 实捕体原样 17 字段（video_platform 1024 等）；
// video_id_type 由调用方定：video_model / multi_video_model 取 0，video_detail 取 1。
func hongguoPlayerBizParam(videoIDType int) map[string]any {
	return map[string]any{
		"video_platform": 1024, "need_all_video_definition": true, "use_os_player": false,
		"video_id_type": videoIDType, "from_video_id": "", "device_level": 3, "source": 4,
		"need_mp4_align": false, "image_shrink_datas_str": "", "screen_width_px": "1080",
		"item_map": map[string]any{}, "caller_scene": "0", "detail_page_version": 0,
		"use_server_dns": false, "use_server_dns_scene": "0", "expire_strategy": "0",
		"disable_digg_stat": false,
	}
}

func hongguoVideoModelValue(value any) (map[string]any, error) {
	if model, ok := value.(map[string]any); ok {
		return model, nil
	}
	encoded, ok := value.(string)
	if !ok || encoded == "" {
		return nil, nil
	}
	if decoded, err := decodeHongguoBase64(encoded); err == nil && len(decoded) > 0 {
		encoded = string(decoded)
	}
	var model map[string]any
	decoder := json.NewDecoder(strings.NewReader(encoded))
	decoder.UseNumber()
	if err := decoder.Decode(&model); err != nil {
		return nil, err
	}
	return model, nil
}

func hongguoAttachKeySeed(model map[string]any, sources ...map[string]any) {
	if model == nil || mapString(model, "key_seed") != "" {
		return
	}
	for _, source := range sources {
		if seed := hongguoFindKeySeed(source, 0); len(seed) > 0 {
			model["key_seed"] = base64.StdEncoding.EncodeToString(seed)
			return
		}
	}
}

func hongguoFindKeySeed(value any, depth int) []byte {
	if depth > 5 {
		return nil
	}
	switch item := value.(type) {
	case map[string]any:
		if raw, ok := item["key_seed"].(string); ok && strings.TrimSpace(raw) != "" {
			if seed, err := decodeHongguoSpadeBase64(raw); err == nil && len(seed) > 0 {
				return seed
			}
		}
		for _, key := range []string{"dynamic_video", "video_info", "data"} {
			if seed := hongguoFindKeySeed(item[key], depth+1); len(seed) > 0 {
				return seed
			}
		}
		for _, child := range item {
			if seed := hongguoFindKeySeed(child, depth+1); len(seed) > 0 {
				return seed
			}
		}
	}
	return nil
}

func decodeHongguoSpadeBase64(value string) ([]byte, error) {
	if decoded, err := decodeHongguoBase64(value); err == nil {
		return decoded, nil
	}
	normalized := strings.NewReplacer("-", "+", "_", "/").Replace(strings.TrimSpace(value))
	decoded, err := base64.StdEncoding.Strict().DecodeString(normalized)
	if err == nil {
		return decoded, nil
	}
	return base64.RawStdEncoding.Strict().DecodeString(normalized)
}

func decryptHongguoSpadeURL(value string, seed []byte) (string, error) {
	if len(seed) == 0 || len(hongguoSpadeDerivationConstants) == 0 {
		return "", errors.New("红果 spade 解密缺少密钥材料")
	}
	raw, err := decodeHongguoSpadeBase64(value)
	if err != nil || len(raw) < 20 {
		return "", errors.New("红果 spade 地址格式无效")
	}
	if raw[0] != 0xA8 || raw[2] != 0x01 || raw[3] != 0x00 {
		return "", errors.New("红果 spade 地址头无效")
	}
	cipherLen := (len(raw) - 4) / aes.BlockSize * aes.BlockSize
	if cipherLen == 0 {
		return "", errors.New("红果 spade 地址无完整密文块")
	}
	first := sha512.Sum512(seed)
	secondInput := make([]byte, 0, len(first)+len(hongguoSpadeDerivationConstants))
	secondInput = append(secondInput, first[:]...)
	secondInput = append(secondInput, hongguoSpadeDerivationConstants...)
	second := sha512.Sum512(secondInput)
	block, err := aes.NewCipher(second[:16])
	if err != nil {
		return "", err
	}
	plain := make([]byte, cipherLen)
	cipher.NewCBCDecrypter(block, second[16:32]).CryptBlocks(plain, raw[4:4+cipherLen])
	if len(plain) == 0 {
		return "", errors.New("红果 spade 地址解密为空")
	}
	if padding := int(plain[len(plain)-1]); padding >= 1 && padding <= aes.BlockSize && padding <= len(plain) {
		plain = plain[:len(plain)-padding]
	}
	plain = bytes.TrimRight(plain, "\x00")
	return strings.TrimSpace(string(plain)), nil
}

func (downloader *Downloader) hongguoMergeFallbackAPI(ctx context.Context, model map[string]any) {
	fallbackURL := hongguoFallbackAPIURL(model)
	if fallbackURL == "" {
		return
	}
	if rows, fetchErr := downloader.hongguoFetchFallbackRows(ctx, fallbackURL, false); fetchErr == nil {
		hongguoAppendFallbackRows(model, rows)
	}
	// 全档不兼容（只剩 bytevc2 或无可用行）时，带兼容参数重读一次再按实际模型选档。
	if hongguoModelCompatibleCount(model) == 0 {
		if rows, fetchErr := downloader.hongguoFetchFallbackRows(ctx, fallbackURL, true); fetchErr == nil {
			hongguoAppendFallbackRows(model, rows)
		}
	}
}

// hongguoFetchFallbackRows：拉备用接口的清晰度行；compat 为真时追加
// codec_type=0 + force_codec=h264（参数名不保证回 h264，仍按实际模型选档）。
func (downloader *Downloader) hongguoFetchFallbackRows(ctx context.Context, rawURL string, compat bool) ([]any, error) {
	target := rawURL
	if compat {
		if parsed, err := url.Parse(rawURL); err == nil {
			query := parsed.Query()
			query.Set("codec_type", "0")
			query.Set("force_codec", "h264")
			parsed.RawQuery = query.Encode()
			target = parsed.String()
		}
	}
	body, fetchErr := downloader.fetchProviderText(ctx, target, "https://novel.snssdk.com/")
	if fetchErr != nil {
		return nil, fetchErr
	}
	return hongguoFallbackVideoRows(body)
}

func hongguoAppendFallbackRows(model map[string]any, rows []any) {
	if len(rows) == 0 {
		return
	}
	merged := anyList(model["video_list"])
	if rowsMap, ok := model["video_list"].(map[string]any); ok && len(merged) == 0 {
		keys := make([]string, 0, len(rowsMap))
		for key := range rowsMap {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			merged = append(merged, rowsMap[key])
		}
	}
	model["video_list"] = append(merged, rows...)
}

// hongguoModelCompatibleCount：模型里非 bytevc2 编码的行数（兼容参数重读的触发条件）。
func hongguoModelCompatibleCount(model map[string]any) int {
	count := 0
	for _, row := range anyList(model["video_list"]) {
		variant, _ := row.(map[string]any)
		if variant == nil {
			continue
		}
		meta := nestedMap(variant, "video_meta")
		codec := strings.ToLower(mapString(meta, "codec_type"))
		if codec == "bytevc2" || strings.Contains(strings.ToLower(mapString(variant, "gear_des_key")), "bytevc2") {
			continue
		}
		count++
	}
	if rows, ok := model["video_list"].(map[string]any); ok {
		for _, row := range rows {
			variant, _ := row.(map[string]any)
			if variant == nil {
				continue
			}
			meta := nestedMap(variant, "video_meta")
			codec := strings.ToLower(mapString(meta, "codec_type"))
			if codec == "bytevc2" || strings.Contains(strings.ToLower(mapString(variant, "gear_des_key")), "bytevc2") {
				continue
			}
			count++
		}
	}
	return count
}

func hongguoFallbackAPIURL(model map[string]any) string {
	var extract func(value any) string
	extract = func(value any) string {
		switch item := value.(type) {
		case string:
			text := strings.TrimSpace(item)
			if strings.HasPrefix(text, "{") {
				var decoded map[string]any
				if err := json.Unmarshal([]byte(text), &decoded); err == nil {
					return strings.TrimSpace(mapString(decoded, "fallback_api"))
				}
				return ""
			}
			return text
		case []any:
			if len(item) > 0 {
				return extract(item[0])
			}
			return ""
		case map[string]any:
			return strings.TrimSpace(mapString(item, "fallback_api"))
		}
		return ""
	}
	return extract(model["fallback_api"])
}

func hongguoFallbackVideoRows(body string) ([]any, error) {
	var outer map[string]any
	decoder := json.NewDecoder(strings.NewReader(body))
	decoder.UseNumber()
	if err := decoder.Decode(&outer); err != nil {
		return nil, errors.New("红果备用取流返回了无效数据")
	}
	info := nestedMap(outer, "video_info", "data")
	if len(info) == 0 {
		info = nestedMap(outer, "data")
	}
	rows := anyList(info["video_list"])
	if rowsMap, ok := info["video_list"].(map[string]any); ok && len(rows) == 0 {
		keys := make([]string, 0, len(rowsMap))
		for key := range rowsMap {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			rows = append(rows, rowsMap[key])
		}
	}
	if len(rows) == 0 {
		return nil, errors.New("红果备用取流未返回清晰度列表")
	}
	out := make([]any, 0, len(rows))
	for _, row := range rows {
		variant, _ := row.(map[string]any)
		if variant == nil {
			continue
		}
		if _, hasEncrypt := variant["encrypt_info"]; !hasEncrypt {
			if spade := mapString(variant, "spade_a"); spade != "" {
				variant["encrypt_info"] = map[string]any{"spade_a": spade}
			}
		}
		out = append(out, variant)
	}
	return out, nil
}

func selectHongguoAppMedia(model map[string]any) (providerMedia, error) {
	variants := anyList(model["video_list"])
	if rows, ok := model["video_list"].(map[string]any); ok && len(variants) == 0 {
		keys := make([]string, 0, len(rows))
		for key := range rows {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			variants = append(variants, rows[key])
		}
	}
	duration, _ := strconv.ParseFloat(mapString(model, "video_duration", "duration"), 64)
	seed := hongguoFindKeySeed(model, 0)
	var keyErr error
	type scoredMedia struct {
		media providerMedia
		score int
	}
	var choices []scoredMedia
	for _, row := range variants {
		variant, _ := row.(map[string]any)
		meta := nestedMap(variant, "video_meta")
		codec := strings.ToLower(mapString(meta, "codec_type"))
		if codec == "bytevc2" || strings.Contains(strings.ToLower(mapString(variant, "gear_des_key")), "bytevc2") {
			continue
		}
		addresses := hongguoMediaAddressesWithSeed(variant, seed)
		if len(addresses) == 0 {
			continue
		}
		media := providerMedia{Referer: "https://novel.snssdk.com/", Duration: time.Duration(duration * float64(time.Second))}
		encryption := nestedMap(variant, "encrypt_info")
		spade := mapString(encryption, "spade_a")
		if spade != "" || encryption["encrypt"] == true || mapString(encryption, "encryption_method") == "cenc-aes-ctr" {
			var err error
			media.CENCKey, err = hongguoContentKey(spade)
			if err != nil {
				keyErr = err
				continue
			}
		}
		height, _ := strconv.Atoi(mapString(meta, "vheight"))
		if definition, err := strconv.Atoi(hongguoQualityNumber.FindString(mapString(meta, "definition"))); err == nil && definition > 0 {
			height = definition
		} else if width, _ := strconv.Atoi(mapString(meta, "vwidth")); width > 0 && (height == 0 || width < height) {
			height = width
		}
		media.Quality = height
		quality := height * 10
		if codec == "h264" || codec == "avc1" {
			quality++
		}
		for _, address := range addresses {
			media.URL = address
			choices = append(choices, scoredMedia{media: media, score: quality})
		}
	}
	if len(choices) > 0 {
		sort.SliceStable(choices, func(i, j int) bool { return choices[i].score > choices[j].score })
		selected := choices[0].media
		for _, choice := range choices {
			selected.Variants = append(selected.Variants, choice.media)
		}
		return selected, nil
	}
	if keyErr != nil {
		return providerMedia{}, fmt.Errorf("红果 App 媒体密钥不可用: %w", keyErr)
	}
	return providerMedia{}, errors.New("红果 App 未返回兼容的媒体，已跳过不支持的编码")
}

func hongguoMediaAddresses(info map[string]any) []string {
	return hongguoMediaAddressesWithSeed(info, nil)
}

func hongguoMediaAddressesWithSeed(info map[string]any, seed []byte) []string {
	var addresses []string
	seen := map[string]bool{}
	var add func(any)
	add = func(value any) {
		switch value := value.(type) {
		case string:
			address := strings.TrimSpace(value)
			if len(address) > 8192 {
				return
			}
			if !isProviderHTTPMediaURL(address) {
				if len(seed) > 0 {
					if decrypted, err := decryptHongguoSpadeURL(address, seed); err == nil && isProviderHTTPMediaURL(decrypted) {
						address = decrypted
					}
				}
			}
			if !isProviderHTTPMediaURL(address) {
				decoded, err := decodeHongguoBase64(address)
				if err != nil {
					return
				}
				address = strings.TrimSpace(string(decoded))
			}
			if isProviderHTTPMediaURL(address) && !seen[address] {
				seen[address] = true
				addresses = append(addresses, address)
			}
		case []any:
			for _, item := range value {
				add(item)
			}
		}
	}
	for _, key := range []string{"main_url", "backup_url", "backup_url_1", "backup_url_2", "backup_urls", "url_list"} {
		add(info[key])
	}
	return addresses
}

var hongguoPlayAuthAPIBase = "https://open.bytedanceapi.com/"

func hongguoPlayAuthFromData(data map[string]any) (string, int64) {
	if data == nil {
		return "", 0
	}
	token := strings.TrimSpace(mapString(data, "play_auth_token"))
	if token == "" {
		return "", 0
	}
	return token, int64(mapInt(data, "expire_time"))
}

func hongguoDecodePlayAuthToken(token string) (string, error) {
	normalized := strings.TrimSpace(token)
	if normalized == "" {
		return "", errors.New("红果播放鉴权为空")
	}
	for _, encoding := range []*base64.Encoding{base64.StdEncoding, base64.URLEncoding, base64.RawStdEncoding, base64.RawURLEncoding} {
		if decoded, err := encoding.DecodeString(normalized); err == nil && len(decoded) > 0 {
			return string(decoded), nil
		}
	}
	return "", errors.New("红果播放鉴权不是有效 Base64")
}

func hongguoCollectPlayAuthURLs(value any, found *[]string) {
	switch item := value.(type) {
	case string:
		if address := strings.TrimSpace(item); isProviderHTTPMediaURL(address) {
			*found = append(*found, address)
		}
	case []any:
		for _, child := range item {
			hongguoCollectPlayAuthURLs(child, found)
		}
	case map[string]any:
		for _, child := range item {
			hongguoCollectPlayAuthURLs(child, found)
		}
	}
}

func (downloader *Downloader) hongguoResolvePlayAuthSecondStage(ctx context.Context, token string, expires int64) (string, error) {
	if strings.TrimSpace(token) == "" {
		return "", errors.New("红果播放鉴权为空")
	}
	if expires > 0 && time.Now().Unix() >= expires-30 {
		return "", errors.New("红果播放鉴权已过期")
	}
	decoded, err := hongguoDecodePlayAuthToken(token)
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(decoded) == "" {
		return "", errors.New("红果播放鉴权解码为空")
	}
	callCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(callCtx, http.MethodGet, hongguoPlayAuthAPIBase+"?"+decoded, nil)
	if err != nil {
		return "", err
	}
	client := downloader.client
	if client == nil {
		client = http.DefaultClient
	}
	response, err := client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return "", fmt.Errorf("红果第二段鉴权返回 HTTP %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 256<<10))
	if err != nil {
		return "", err
	}
	text := strings.TrimSpace(string(body))
	if isProviderHTTPMediaURL(text) {
		return text, nil
	}
	var parsed any
	decoder := json.NewDecoder(strings.NewReader(text))
	decoder.UseNumber()
	if err := decoder.Decode(&parsed); err != nil {
		return "", errors.New("红果第二段鉴权未返回可用地址")
	}
	var found []string
	hongguoCollectPlayAuthURLs(parsed, &found)
	for _, address := range found {
		if strings.HasSuffix(strings.ToLower(address), ".m3u8") {
			return address, nil
		}
	}
	if len(found) > 0 {
		return found[0], nil
	}
	return "", errors.New("红果第二段鉴权未返回可用地址")
}

func (downloader *Downloader) hongguoApplyPlayAuth(ctx context.Context, media providerMedia, sources ...map[string]any) providerMedia {
	for _, source := range sources {
		token, expires := hongguoPlayAuthFromData(source)
		if token == "" {
			continue
		}
		media.PlayAuthToken = token
		media.PlayAuthExpires = expires
		if address, err := downloader.hongguoResolvePlayAuthSecondStage(ctx, token, expires); err == nil && address != "" && address != media.URL {
			media.URL = address
		}
		return media
	}
	return media
}
