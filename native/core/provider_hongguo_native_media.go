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
	"net/http"
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

func (downloader *Downloader) resolveHongguoAppMedia(ctx context.Context, videoID string) (providerMedia, error) {
	if !hongguoNumericID.MatchString(videoID) {
		return providerMedia{}, errors.New("红果视频 ID 无效")
	}
	if err := downloader.ensureHongguoDevice(ctx, ""); err != nil {
		return providerMedia{}, err
	}
	if downloader.hongguoDeviceLimited() {
		downloader.ensureHongguoDevice(ctx, downloader.hongguoDeviceID())
	}
	media, err := downloader.resolveHongguoAppMediaLine(ctx, videoID)
	if err == nil {
		return media, nil
	}
	if !errors.Is(err, errHongguoAppEmptyBody) {
		return providerMedia{}, err
	}
	overseaCtx := context.WithValue(ctx, hongguoBaseURLOverrideKey{}, hongguoOverseaAppBaseURL)
	media, overseaErr := downloader.resolveHongguoAppMediaLine(overseaCtx, videoID)
	if overseaErr == nil {
		return media, nil
	}
	if errors.Is(overseaErr, errHongguoAppEmptyBody) {
		downloader.markHongguoPlayerSuspended()
		return providerMedia{}, fmt.Errorf("红果 App 大陆线与海外线轮换后仍未返回有效数据，可能被限流: %w", overseaErr)
	}
	return providerMedia{}, overseaErr
}

func (downloader *Downloader) resolveHongguoAppMediaLine(ctx context.Context, videoID string) (providerMedia, error) {
	if media, err := downloader.resolveHongguoMultiModel(ctx, videoID); err == nil {
		downloader.clearHongguoDeviceLimited()
		return media, nil
	} else if ctx.Err() != nil {
		return providerMedia{}, ctx.Err()
	}
	payload := map[string]any{
		"video_id": videoID, "content_type": 1,
		"biz_param": map[string]any{"need_all_video_definition": true, "video_platform": 3},
	}
	var lastErr error
	for attempt := 0; attempt <= hongguoDeviceRotations; attempt++ {
		if attempt > 0 {
			if err := downloader.ensureHongguoDevice(ctx, downloader.hongguoDeviceID()); err != nil {
				return providerMedia{}, err
			}
		}
		result, err := downloader.hongguoAppRequestInternal(ctx, http.MethodPost, "/novel/player/video_model/v1/", nil, payload, true)
		if err != nil {
			if errors.Is(err, errHongguoAppEmptyBody) {
				downloader.markHongguoDeviceLimited()
				lastErr = err
				continue
			}
			return providerMedia{}, err
		}
		data := nestedMap(result, "data")
		model, err := hongguoVideoModelValue(data["video_model"])
		if err != nil {
			return providerMedia{}, errors.New("红果 App 播放信息格式异常")
		}
		if len(model) == 0 {
			if rows := anyList(data["video_list"]); len(rows) > 0 {
				model = map[string]any{
					"video_list":     data["video_list"],
					"video_duration": data["video_duration"],
					"duration":       data["duration"],
				}
			}
		}
		hongguoAttachKeySeed(model, data)
		downloader.hongguoMergeFallbackAPI(ctx, model)
		if len(model) == 0 {
			downloader.markHongguoDeviceLimited()
			lastErr = errHongguoAppEmptyBody
			continue
		}
		downloader.clearHongguoDeviceLimited()
		return selectHongguoAppMedia(model)
	}
	if lastErr != nil {
		return providerMedia{}, lastErr
	}
	return providerMedia{}, errHongguoAppEmptyBody
}

func (downloader *Downloader) resolveHongguoMultiModel(ctx context.Context, videoID string) (providerMedia, error) {
	payload := map[string]any{
		"mixed_video_id_map": map[string]any{"1004": []any{videoID}},
		"biz_param":          map[string]any{"need_all_video_definition": true, "video_platform": 3},
	}
	result, err := downloader.hongguoAppRequestInternal(ctx, http.MethodPost, "/novel/player/multi_video_model/v1/", nil, payload, true)
	if err != nil {
		return providerMedia{}, err
	}
	data := nestedMap(result, "data")
	entry := hongguoMultiEntry(data, videoID)
	if entry == nil {
		return providerMedia{}, errHongguoAppEmptyBody
	}
	model, err := hongguoVideoModelValue(entry["video_model"])
	if err != nil {
		return providerMedia{}, errors.New("红果 App 播放信息格式异常")
	}
	if model == nil {
		model = map[string]any{}
	}
	if len(model) == 0 {
		if rows := anyList(entry["video_list"]); len(rows) > 0 {
			model["video_list"] = entry["video_list"]
			model["video_duration"] = entry["video_duration"]
			model["duration"] = entry["duration"]
		}
	}
	if len(model) == 0 {
		return providerMedia{}, errHongguoAppEmptyBody
	}
	hongguoAttachKeySeed(model, entry, data)
	downloader.hongguoMergeFallbackAPI(ctx, model)
	return selectHongguoAppMedia(model)
}

func hongguoMultiEntry(data map[string]any, videoID string) map[string]any {
	if entry, ok := data[videoID].(map[string]any); ok {
		return entry
	}
	for _, value := range data {
		if entry, ok := value.(map[string]any); ok {
			return entry
		}
		if rows := anyList(value); len(rows) > 0 {
			if entry, ok := rows[0].(map[string]any); ok {
				return entry
			}
		}
	}
	if _, ok := data["video_model"]; ok {
		return data
	}
	if _, ok := data["video_list"]; ok {
		return data
	}
	return nil
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
	if fallbackURL := hongguoFallbackAPIURL(model); fallbackURL == "" {
		return
	} else if body, fetchErr := downloader.fetchProviderText(ctx, fallbackURL, "https://novel.snssdk.com/"); fetchErr == nil {
		if rows, parseErr := hongguoFallbackVideoRows(body); parseErr == nil && len(rows) > 0 {
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
	}
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
