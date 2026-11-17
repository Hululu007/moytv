package core

// V5 single-leg playback.
//
// Go port of upstream fqapp endpoints/video.rs fetch_v5_video_model plus the
// client.rs v5_playback retry policy (PR #425, 2b16621e + d24f229a):
// one POST to /novel/player/multi_video_model/player/v1 with the V5
// signature, fresh signing on every attempt. HTTP 401/403 swaps the device
// (at most 3 device attempts); 429/5xx and transport errors retry on the
// same device with re-signing (200ms doubling backoff capped at 5s, at most
// 2 transient retries, Retry-After honoured up to 5s). An empty body or a
// business-code failure is terminal: no device swap, no oversea line, no
// hidden retry. The V5 endpoint already lives on the oversea host, so the
// old mainland/oversea line fallback has nothing left to fall back to.
//
// The 90-second total budget wrapper, the device-renewal prologue, the
// prefetch cache, the fallback-API merge, the spade/CENC variant selection
// and the play-auth second stage are Moyi-local architecture around this
// leg and are preserved unchanged.

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const hongguoV5PlayerURL = "https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1"

const (
	// hongguoV5DeviceAttempts: upstream max_retries (client.rs).
	hongguoV5DeviceAttempts = 3
	// hongguoV5TransientRetries: upstream TRANSIENT_RETRIES.
	hongguoV5TransientRetries = 2
	// hongguoV5TransientBackoff: upstream TRANSIENT_BACKOFF, doubled per
	// retry and capped at hongguoV5RetryAfterCap.
	hongguoV5TransientBackoff = 200 * time.Millisecond
	// hongguoV5RetryAfterCap: upstream RETRY_AFTER_CAP.
	hongguoV5RetryAfterCap = 5 * time.Second
	// hongguoV5DeviceRetryPause: upstream 100ms pause between device attempts.
	hongguoV5DeviceRetryPause = 100 * time.Millisecond
	// hongguoV5RequestTimeout: per-attempt timeout, same as the app request path.
	hongguoV5RequestTimeout = 20 * time.Second
	// hongguoV5BodyLimit: response read cap for the video-model JSON.
	hongguoV5BodyLimit = 4 << 20
)

// hongguoV5PlaybackBody: upstream v5_playback_body shape. Field order is the
// upstream listing order; the gzip bytes actually sent are what get signed,
// so any stable encoding is correct as long as signing hashes these bytes.
type hongguoV5PlaybackBody struct {
	BizParam struct {
		DetailPageVersion      int  `json:"detail_page_version"`
		DeviceLevel            int  `json:"device_level"`
		DisableDiggStat        bool `json:"disable_digg_stat"`
		DisableVideoRelateBook bool `json:"disable_video_relate_book"`
		NeedAllVideoDefinition bool `json:"need_all_video_definition"`
		NeedMP4Align           bool `json:"need_mp4_align"`
		UseOSPlayer            bool `json:"use_os_player"`
		UseServerDNS           bool `json:"use_server_dns"`
		VideoPlatform          int  `json:"video_platform"`
	} `json:"biz_param"`
	MixedVideoIDMap map[string][]string `json:"mixed_video_id_map"`
	DRScene         string              `json:"dr_scene"`
}

// hongguoV5PlaybackBodyBytes: the exact gzip bytes to send. Upcoming episode
// IDs ride in the same "1004" array (the old multi leg's prefetch shape);
// the server returns one model per ID and the extras feed the prefetch cache.
func hongguoV5PlaybackBodyBytes(videoID string, upcoming []string) ([]byte, error) {
	ids := []string{videoID}
	for _, id := range upcoming {
		if len(ids) > 2 {
			break
		}
		if hongguoNumericID.MatchString(id) && id != videoID {
			ids = append(ids, id)
		}
	}
	var body hongguoV5PlaybackBody
	body.BizParam.DetailPageVersion = 0
	body.BizParam.DeviceLevel = 1
	body.BizParam.DisableDiggStat = false
	body.BizParam.DisableVideoRelateBook = false
	body.BizParam.NeedAllVideoDefinition = true
	body.BizParam.NeedMP4Align = false
	body.BizParam.UseOSPlayer = false
	body.BizParam.UseServerDNS = false
	body.BizParam.VideoPlatform = 1024
	body.MixedVideoIDMap = map[string][]string{"1004": ids}
	body.DRScene = "player"
	plain, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	writer := gzip.NewWriter(&buf)
	if _, err := writer.Write(plain); err != nil {
		return nil, err
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// hongguoV5ModelEntry: upstream video_models resolution order — the "1004"
// group first, then the direct video-ID key, then any group containing the
// ID, then the legacy direct video_model / video_list shape.
func hongguoV5ModelEntry(data map[string]any, videoID string) map[string]any {
	if group, ok := data["1004"].(map[string]any); ok {
		if entry, ok := group[videoID].(map[string]any); ok {
			return entry
		}
	}
	if entry, ok := data[videoID].(map[string]any); ok {
		return entry
	}
	for _, value := range data {
		if group, ok := value.(map[string]any); ok {
			if entry, ok := group[videoID].(map[string]any); ok {
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

func hongguoV5ModelFromEntry(entry map[string]any) (map[string]any, error) {
	model, err := hongguoVideoModelValue(entry["video_model"])
	if err != nil {
		return nil, errors.New("红果 App 播放信息格式异常")
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
	return model, nil
}

// hongguoV5BusinessError: the business-code check the old legs got for free
// from hongguoAppRequestInternal. The V5 leg sends its own request, so it
// replicates the check: any non-zero code fails; the device-rejected codes
// keep their sentinel (the caller-facing signal stays identical) but under
// V5 they are terminal — no device swap.
func hongguoV5BusinessError(result map[string]any) error {
	code := firstNonEmpty(mapString(result, "code", "Code", "status_code"), mapString(nestedMap(result, "BaseResp"), "StatusCode"))
	if code == "" || code == "0" {
		return nil
	}
	if hongguoIsDeviceRejectedCode(code) {
		return fmt.Errorf("%w（业务码 %s）", errHongguoDeviceRejected, code)
	}
	if detail := firstNonEmpty(mapString(result, "message", "msg", "description"), mapString(nestedMap(result, "data"), "message", "msg", "description")); detail != "" {
		return fmt.Errorf("红果 App 接口暂不可用（%s：%s）", truncate(code, 20), truncate(detail, 100))
	}
	return fmt.Errorf("红果 App 接口暂不可用（%s）", truncate(code, 20))
}

func hongguoV5ParseRetryAfter(value string) time.Duration {
	seconds, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || seconds <= 0 {
		return 0
	}
	wait := time.Duration(seconds) * time.Second
	if wait > hongguoV5RetryAfterCap {
		return hongguoV5RetryAfterCap
	}
	return wait
}

// hongguoV5EmptyBodyError: the empty-body outcome. Wording keeps the
// rate-limit hint the three media slots key their user-facing message on
// ("限流" substring + the suspend window). Terminal under V5: the caller
// must not swap devices or retry.
func hongguoV5EmptyBodyError() error {
	return fmt.Errorf("%w：设备或游客会话可能被限流，请稍后重试", errHongguoAppEmptyBody)
}

// hongguoV5Do: sends one V5 attempt without the shared request limiter.
// The limiter's 403/429 host cooldown (60s) would veto the upstream
// retry policy: a 403 must swap the device immediately and a 429 must
// retry on the same device, both against the same host. The V5 policy's
// own bounded budget (3 devices x 3 attempts inside the 90s chain budget)
// is the operative protection for this endpoint. Bypassing the limiter
// also keeps V5 403/429s from poisoning the host for the account chain,
// which shares the sinfonlinea host. Precedent: the play-auth second
// stage also sends through downloader.client directly. The per-attempt
// timeout and the source-health observation are preserved; only the
// limiter gate and its cooldown are skipped.
func (downloader *Downloader) hongguoV5Do(request *http.Request) (*http.Response, error) {
	callCtx, cancel := context.WithTimeout(request.Context(), hongguoV5RequestTimeout)
	prepared := request.WithContext(callCtx)
	client := downloader.client
	if client == nil {
		client = http.DefaultClient
	}
	response, err := client.Do(prepared)
	if err != nil {
		cancel()
		return nil, err
	}
	observeSourceResponse(request.Context(), response)
	response.Body = &limitedResponseBody{ReadCloser: response.Body, release: cancel}
	return response, nil
}

// hongguoV5FetchModel: the single V5 leg. Cache-take first, then the
// upstream retry policy. Never attaches account cookies: the request is
// built directly with only the V5 signature headers.
func (downloader *Downloader) hongguoV5FetchModel(ctx context.Context, videoID string, upcoming []string) (providerMedia, error) {
	if cached, ok := downloader.hongguoTakeUpcomingModel(videoID); ok {
		downloader.hongguoMergeFallbackAPI(ctx, cached)
		if media, err := selectHongguoAppMedia(cached); err == nil {
			downloader.clearHongguoDeviceLimited()
			return downloader.hongguoApplyPlayAuth(ctx, media, cached), nil
		}
	}
	compressed, err := hongguoV5PlaybackBodyBytes(videoID, upcoming)
	if err != nil {
		return providerMedia{}, err
	}
	ids := []string{videoID}
	for _, id := range upcoming {
		if len(ids) > 2 {
			break
		}
		if hongguoNumericID.MatchString(id) && id != videoID {
			ids = append(ids, id)
		}
	}

	var lastErr error
	for deviceAttempt := 0; deviceAttempt < hongguoV5DeviceAttempts; deviceAttempt++ {
		if deviceAttempt > 0 {
			if err := hongguoSleepContext(ctx, hongguoV5DeviceRetryPause); err != nil {
				return providerMedia{}, err
			}
			if err := downloader.reregisterHongguoDevice(ctx); err != nil {
				return providerMedia{}, err
			}
		}
		snapshot := downloader.hongguoCatalogSnapshot()
		identity := hongguoV5Identity{DeviceID: snapshot.DeviceID, InstallID: snapshot.InstallID, CDID: downloader.hongguoCDID()}

		delay := hongguoV5TransientBackoff
		var lastRetryAfter string
		deviceFailed := false
		for transientAttempt := 0; transientAttempt <= hongguoV5TransientRetries; transientAttempt++ {
			var wait time.Duration
			if transientAttempt > 0 {
				wait = delay
				delay *= 2
				if delay > hongguoV5RetryAfterCap {
					delay = hongguoV5RetryAfterCap
				}
				if retryAfter := hongguoV5ParseRetryAfter(lastRetryAfter); retryAfter > 0 {
					wait = retryAfter
				}
				if err := hongguoSleepContext(ctx, wait); err != nil {
					return providerMedia{}, err
				}
			}
			signed, err := hongguoV5SignPlayback(hongguoV5PlayerURL, compressed, identity)
			if err != nil {
				return providerMedia{}, err
			}
			request, err := http.NewRequestWithContext(ctx, http.MethodPost, signed.URL, bytes.NewReader(compressed))
			if err != nil {
				return providerMedia{}, err
			}
			for key, values := range signed.Headers {
				for _, value := range values {
					request.Header.Add(key, value)
				}
			}
			response, err := downloader.hongguoV5Do(request)
			if err != nil {
				if ctx.Err() != nil {
					return providerMedia{}, ctx.Err()
				}
				lastErr = err
				lastRetryAfter = ""
				continue
			}
			content, readErr := io.ReadAll(io.LimitReader(response.Body, hongguoV5BodyLimit+1))
			response.Body.Close()
			if readErr != nil {
				if ctx.Err() != nil {
					return providerMedia{}, ctx.Err()
				}
				lastErr = readErr
				lastRetryAfter = ""
				continue
			}
			switch {
			case response.StatusCode == http.StatusUnauthorized || response.StatusCode == http.StatusForbidden:
				downloader.markHongguoDeviceLimited()
				lastErr = fmt.Errorf("红果 V5 播放接口 HTTP %d", response.StatusCode)
				deviceFailed = true
			case response.StatusCode == http.StatusTooManyRequests || response.StatusCode >= 500:
				lastErr = fmt.Errorf("红果 V5 播放接口 HTTP %d", response.StatusCode)
				lastRetryAfter = response.Header.Get("Retry-After")
			case response.StatusCode != http.StatusOK:
				return providerMedia{}, fmt.Errorf("红果 V5 播放接口 HTTP %d", response.StatusCode)
			case len(bytes.TrimSpace(content)) == 0:
				downloader.markHongguoPlayerSuspended()
				return providerMedia{}, hongguoV5EmptyBodyError()
			case len(content) > hongguoV5BodyLimit:
				return providerMedia{}, errors.New("红果 App 接口未返回有效数据")
			default:
				var result map[string]any
				decoder := json.NewDecoder(bytes.NewReader(content))
				decoder.UseNumber()
				if err := decoder.Decode(&result); err != nil || result == nil {
					return providerMedia{}, errors.New("红果 App 接口返回格式异常")
				}
				if err := hongguoV5BusinessError(result); err != nil {
					return providerMedia{}, err
				}
				data := nestedMap(result, "data")
				entry := hongguoV5ModelEntry(data, videoID)
				if entry == nil {
					downloader.markHongguoPlayerSuspended()
					return providerMedia{}, hongguoV5EmptyBodyError()
				}
				model, err := hongguoV5ModelFromEntry(entry)
				if err != nil {
					return providerMedia{}, err
				}
				if len(model) == 0 {
					downloader.markHongguoPlayerSuspended()
					return providerMedia{}, hongguoV5EmptyBodyError()
				}
				for _, id := range ids[1:] {
					if next := hongguoV5ModelEntry(data, id); next != nil {
						if nextModel, err := hongguoV5ModelFromEntry(next); err == nil && len(nextModel) > 0 {
							hongguoAttachKeySeed(nextModel, next, data)
							downloader.hongguoOfferUpcomingModel(id, nextModel)
						}
					}
				}
				hongguoAttachKeySeed(model, entry, data)
				downloader.hongguoMergeFallbackAPI(ctx, model)
				downloader.clearHongguoDeviceLimited()
				downloader.clearHongguoPlayerSuspended()
				media, err := selectHongguoAppMedia(model)
				if err != nil {
					return providerMedia{}, err
				}
				return downloader.hongguoApplyPlayAuth(ctx, media, entry, data), nil
			}
			if deviceFailed {
				break
			}
		}
		if !deviceFailed {
			return providerMedia{}, lastErr
		}
	}
	return providerMedia{}, fmt.Errorf("红果 V5 播放接口换设备 %d 次后仍失败: %v", hongguoV5DeviceAttempts, lastErr)
}
