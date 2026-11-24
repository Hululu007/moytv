package core

// V5 playback ladder (upstream fqapp endpoints/video.rs fetch_playback_model
// + fetch_resolved_playback_model, 2f31ba83 + bef83c90).
//
// Doors in preference order: anon -> v5 -> model-a -> model-c -> tab-b.
// Each door keeps its own health in hongguoPlaybackRouteState: an empty
// HTTP 200 body parks that door for 30s, a non-empty failure for 5s. An
// empty body is re-probed once on the same door (250ms, guarded). A body
// that parses but yields no playable tier is recorded as rejected and the
// ladder keeps going; when every door has been tried and rotation is due,
// the identity rotates at most once per request (pool device re-register +
// anonymous identity refresh), skip_routes clears, and the full ladder runs
// again. Prefetch never runs here: this entry point is always foreground.
//
// The 90-second total budget wrapper, the device-renewal prologue, the
// prefetch cache, the fallback-API merge, the spade/CENC variant selection
// and the play-auth second stage are Moyi-local architecture around this
// ladder and are preserved unchanged.
//
// Two deliberate deviations from upstream, both documented in REPORT.md:
//   - the pool-device budget is shared per request (at most 3 device swaps
//     across all doors) instead of 3 attempts per door: this core has no
//     bounded device pool to rotate through, and the old single leg already
//     capped re-registration at 3 per request;
//   - the v5 door body keeps the Moyi-local upcoming-episode prefetch shape
//     ("1004": [current, next...]); the anon and model bodies are single
//     episode exactly as upstream builds them.

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

// hongguoAnonPlayerURL: the same player endpoint with the trailing slash
// the anonymous door requires. It is a different route on the server side,
// not a cosmetic spelling.
const hongguoAnonPlayerURL = "https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1/"

const hongguoV5VideoModelPath = "/novel/player/video_model/v1/"
const hongguoV5VideoTabPath = "/reading/bookapi/video_tab/multi_video_model/v1/"

const (
	// hongguoV5DeviceAttempts: shared per-request pool-device swap budget
	// (upstream max_retries is per door; see the file header).
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
	// hongguoV5MaxPlaybackAttempts: upstream MAX_PLAYBACK_ATTEMPTS, the
	// total door attempts (including one same-door reprobe) per request.
	hongguoV5MaxPlaybackAttempts = 8
	// hongguoV5SameDoorReprobeDelay: upstream SAME_DOOR_REPROBE_DELAY.
	hongguoV5SameDoorReprobeDelay = 250 * time.Millisecond
	// hongguoV5ReprobeMinBudget: upstream REPROBE_MIN_BUDGET; a reprobe
	// only runs when more than this remains before the request deadline.
	hongguoV5ReprobeMinBudget = 1 * time.Second
	// hongguoV5RotationMinBudget: upstream ROTATION_MIN_BUDGET; rotation
	// only runs when more than this remains before the request deadline.
	hongguoV5RotationMinBudget = 1500 * time.Millisecond
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

func hongguoV5GzipJSON(body any) ([]byte, error) {
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

// hongguoV5AnonPlaybackBodyBytes: upstream anonymous_playback_body — the v5
// shape plus video_id and content_type 1, current episode only.
func hongguoV5AnonPlaybackBodyBytes(videoID string) ([]byte, error) {
	return hongguoV5GzipJSON(map[string]any{
		"biz_param": map[string]any{
			"detail_page_version": 0, "device_level": 1, "disable_digg_stat": false,
			"disable_video_relate_book": false, "need_all_video_definition": true,
			"need_mp4_align": false, "use_os_player": false, "use_server_dns": false,
			"video_platform": 1024,
		},
		"dr_scene":           "player",
		"mixed_video_id_map": map[string][]string{"1004": {videoID}},
		"video_id":           videoID,
		"content_type":       1,
	})
}

// hongguoV5VideoModelBodyBytes: upstream video_model_body — an independent
// shape, NOT the v5 body with a different URL. The model door takes the
// single episode id plus content_type 1004.
func hongguoV5VideoModelBodyBytes(videoID string) ([]byte, error) {
	return hongguoV5GzipJSON(map[string]any{
		"biz_param": map[string]any{
			"detail_page_version": 0, "device_level": 3, "disable_digg_stat": false,
			"from_video_id": "", "need_all_video_definition": true, "need_mp4_align": false,
			"source": 9, "use_os_player": false, "use_server_dns": false, "video_platform": 3,
		},
		"content_type": 1004,
		"video_id":     videoID,
	})
}

// hongguoV5VideoTabQuery: upstream video_tab_query — the official app's
// snake_case GetVideoModelRequest parameters, nine fields.
func hongguoV5VideoTabQuery(videoID string) [][2]string {
	return [][2]string{
		{"video_id", videoID},
		{"video_id_type", "0"},
		{"device_level", "1"},
		{"need_all_video_definition", "1"},
		{"need_mp4_align", "0"},
		{"use_os_player", "0"},
		{"video_platform", "1024"},
		{"source", "0"},
		{"from_video_id", ""},
	}
}

// hongguoV5VideoTabShape: upstream video_tab_player_shape. The tab payload
// is validated (code 0, data present) and re-wrapped as {"data": data} so
// the shared model parser can read it. A business code or a payload without
// data is a failed door, never an empty one.
func hongguoV5VideoTabShape(raw []byte) ([]byte, bool) {
	var root map[string]any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&root); err != nil || root == nil {
		return nil, false
	}
	code := int64(0)
	if value, ok := root["code"]; ok {
		code, _ = hongguoV5TabCodeValue(value)
	} else if value, ok := root["Code"]; ok {
		code, _ = hongguoV5TabCodeValue(value)
	}
	if code != 0 {
		return nil, false
	}
	data, ok := root["data"]
	if !ok {
		return nil, false
	}
	shaped, err := json.Marshal(map[string]any{"data": data})
	if err != nil {
		return nil, false
	}
	return shaped, true
}

func hongguoV5TabCodeValue(value any) (int64, bool) {
	switch typed := value.(type) {
	case json.Number:
		code, err := typed.Int64()
		return code, err == nil
	case float64:
		return int64(typed), true
	case string:
		code, err := strconv.ParseInt(strings.TrimSpace(typed), 10, 64)
		return code, err == nil
	}
	return 0, false
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
// ("限流" substring + the suspend window). It is returned only after the
// whole ladder is exhausted; a single door's empty body first re-probes,
// then falls through to the next door.
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

// hongguoPlaybackAttemptOutcome: what one playback-door attempt produced.
type hongguoPlaybackAttemptOutcome int

const (
	// hongguoPlaybackAttemptBody: a non-empty HTTP 200 body.
	hongguoPlaybackAttemptBody hongguoPlaybackAttemptOutcome = iota
	// hongguoPlaybackAttemptEmpty: HTTP 200 with zero bytes.
	hongguoPlaybackAttemptEmpty
	// hongguoPlaybackAttemptFailed: transport error, unusable status or a
	// body without a usable model.
	hongguoPlaybackAttemptFailed
	// hongguoPlaybackAttemptDeadline: the request deadline passed before
	// the door answered.
	hongguoPlaybackAttemptDeadline
)

type hongguoPlaybackAttempt struct {
	outcome hongguoPlaybackAttemptOutcome
	body    []byte
	// err: the last transport/status error of a failed attempt, for the
	// ladder's final error. Empty outcomes carry none.
	err error
}

func hongguoPlaybackDeadlineAttempt(ctx context.Context) hongguoPlaybackAttempt {
	if ctx.Err() != nil {
		return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptDeadline}
	}
	return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed}
}

// hongguoV5LadderBodies: the three request bodies, built once per request.
type hongguoV5LadderBodies struct {
	anon  []byte
	v5    []byte
	model []byte
}

// hongguoV5LadderRecovery: per-request ladder state (upstream
// PlaybackRecovery).
type hongguoV5LadderRecovery struct {
	skipRoutes map[hongguoPlaybackRoute]bool
	attempts   int
	reprobed   bool
	rotated    bool
	allEmpty   bool
	lastErr    error
}

// hongguoV5DeviceBudget: the shared per-request pool-device swap budget.
// The initial device is free; each re-registration consumes one swap.
type hongguoV5DeviceBudget struct {
	swapsLeft int
}

func (budget *hongguoV5DeviceBudget) takeSwap() bool {
	if budget.swapsLeft <= 0 {
		return false
	}
	budget.swapsLeft--
	return true
}

// hongguoV5RemainingBudget: time left before the request deadline; a
// request without a deadline is treated as unbounded.
func hongguoV5RemainingBudget(ctx context.Context) time.Duration {
	deadline, ok := ctx.Deadline()
	if !ok {
		return time.Duration(1<<62 - 1)
	}
	return time.Until(deadline)
}

// hongguoV5FetchModel: the playback ladder. Cache-take first, then the
// upstream fetch/resolve loop. Never attaches account cookies: every door
// request is built directly with only its signature headers.
func (downloader *Downloader) hongguoV5FetchModel(ctx context.Context, videoID string, upcoming []string) (providerMedia, error) {
	if cached, ok := downloader.hongguoTakeUpcomingModel(videoID); ok {
		downloader.hongguoMergeFallbackAPI(ctx, cached)
		if media, err := selectHongguoAppMedia(cached); err == nil {
			downloader.clearHongguoDeviceLimited()
			return downloader.hongguoApplyPlayAuth(ctx, media, cached), nil
		}
	}
	anonBody, err := hongguoV5AnonPlaybackBodyBytes(videoID)
	if err != nil {
		return providerMedia{}, err
	}
	compressed, err := hongguoV5PlaybackBodyBytes(videoID, upcoming)
	if err != nil {
		return providerMedia{}, err
	}
	modelBody, err := hongguoV5VideoModelBodyBytes(videoID)
	if err != nil {
		return providerMedia{}, err
	}
	bodies := hongguoV5LadderBodies{anon: anonBody, v5: compressed, model: modelBody}
	ids := []string{videoID}
	for _, id := range upcoming {
		if len(ids) > 2 {
			break
		}
		if hongguoNumericID.MatchString(id) && id != videoID {
			ids = append(ids, id)
		}
	}
	recovery := &hongguoV5LadderRecovery{skipRoutes: map[hongguoPlaybackRoute]bool{}, allEmpty: true}
	budget := &hongguoV5DeviceBudget{swapsLeft: hongguoV5DeviceAttempts}
	state := &downloader.hongguoClient().playbackRoutes
	var rejectedErr error

	for {
		if recovery.attempts >= hongguoV5MaxPlaybackAttempts || ctx.Err() != nil {
			break
		}
		before := recovery.attempts
		parsed, fetchErr := downloader.hongguoV5FetchParsed(ctx, videoID, bodies, recovery, budget)
		if fetchErr != nil {
			return providerMedia{}, fetchErr
		}
		if parsed != nil {
			media, selectErr := downloader.hongguoV5SelectMedia(ctx, parsed, videoID, ids)
			if selectErr == nil {
				state.Success(parsed.route, hongguoPlaybackNowMS())
				state.NoteRound(false)
				return media, nil
			}
			if rejectedErr == nil {
				rejectedErr = selectErr
			}
			continue
		}
		if recovery.attempts > before {
			continue
		}
		if recovery.rotated {
			break
		}
		nowMS := hongguoPlaybackNowMS()
		canRotate := rejectedErr != nil || (state.RotationPaced(nowMS, false) && (state.Exhausted(nowMS) || state.RotateDue(nowMS, false)))
		if !canRotate || recovery.attempts >= hongguoV5MaxPlaybackAttempts || hongguoV5RemainingBudget(ctx) <= hongguoV5RotationMinBudget {
			break
		}
		recovery.rotated = true
		rotated := downloader.hongguoV5RotatePlaybackIdentity(ctx)
		state.NoteRotate(nowMS, rotated)
		if !rotated {
			break
		}
		recovery.skipRoutes = map[hongguoPlaybackRoute]bool{}
	}

	state.NoteRound(recovery.allEmpty)
	if recovery.allEmpty {
		downloader.markHongguoPlayerSuspended()
	}
	if rejectedErr != nil {
		return providerMedia{}, rejectedErr
	}
	if recovery.lastErr != nil {
		return providerMedia{}, recovery.lastErr
	}
	return providerMedia{}, hongguoV5EmptyBodyError()
}

// hongguoV5ParsedDoor: one door body that parsed cleanly (even when it
// holds no model for this episode — that is the rejected case, not a fetch
// failure).
type hongguoV5ParsedDoor struct {
	data  map[string]any
	route hongguoPlaybackRoute
}

// hongguoV5FetchParsed: upstream fetch_parsed_playback_model — one ladder
// pass over the doors, then JSON parse and the business-code check. A body
// that fails either check parks its route as a non-empty failure and yields
// nil, so the ladder moves on; only a cancelled context returns an error.
func (downloader *Downloader) hongguoV5FetchParsed(ctx context.Context, videoID string, bodies hongguoV5LadderBodies, recovery *hongguoV5LadderRecovery, budget *hongguoV5DeviceBudget) (*hongguoV5ParsedDoor, error) {
	raw, route, ok, err := downloader.hongguoV5FetchDoorBody(ctx, videoID, bodies, recovery, budget)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, nil
	}
	var result map[string]any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&result); err != nil || result == nil {
		state := &downloader.hongguoClient().playbackRoutes
		state.Failed(route, hongguoPlaybackNowMS(), false)
		recovery.lastErr = errors.New("红果 App 接口返回格式异常")
		return nil, nil
	}
	if err := hongguoV5BusinessError(result); err != nil {
		state := &downloader.hongguoClient().playbackRoutes
		state.Failed(route, hongguoPlaybackNowMS(), false)
		recovery.lastErr = err
		return nil, nil
	}
	data := nestedMap(result, "data")
	return &hongguoV5ParsedDoor{data: data, route: route}, nil
}

// hongguoV5SelectMedia: the resolve step — pick the model for this episode
// out of the parsed data and turn it into playable media. A body that parses
// but yields no playable tier is the rejected case: the caller records it
// and the ladder keeps going.
func (downloader *Downloader) hongguoV5SelectMedia(ctx context.Context, parsed *hongguoV5ParsedDoor, videoID string, ids []string) (providerMedia, error) {
	entry := hongguoV5ModelEntry(parsed.data, videoID)
	if entry == nil {
		return providerMedia{}, hongguoV5EmptyBodyError()
	}
	model, err := hongguoV5ModelFromEntry(entry)
	if err != nil {
		return providerMedia{}, err
	}
	if len(model) == 0 {
		return providerMedia{}, hongguoV5EmptyBodyError()
	}
	for _, id := range ids[1:] {
		if next := hongguoV5ModelEntry(parsed.data, id); next != nil {
			if nextModel, err := hongguoV5ModelFromEntry(next); err == nil && len(nextModel) > 0 {
				hongguoAttachKeySeed(nextModel, next, parsed.data)
				downloader.hongguoOfferUpcomingModel(id, nextModel)
			}
		}
	}
	hongguoAttachKeySeed(model, entry, parsed.data)
	downloader.hongguoMergeFallbackAPI(ctx, model)
	downloader.clearHongguoDeviceLimited()
	downloader.clearHongguoPlayerSuspended()
	media, err := selectHongguoAppMedia(model)
	if err != nil {
		return providerMedia{}, err
	}
	return downloader.hongguoApplyPlayAuth(ctx, media, entry, parsed.data), nil
}

// hongguoV5FetchDoorBody: upstream fetch_playback_model — one pass over the
// planned doors. The plan already excludes parked doors, except the
// foreground all-cooling case where every door comes back ordered by
// recovery time and is probed anyway. A door's empty body is re-probed once
// on the same door (250ms, guarded); a non-empty body returns immediately.
func (downloader *Downloader) hongguoV5FetchDoorBody(ctx context.Context, videoID string, bodies hongguoV5LadderBodies, recovery *hongguoV5LadderRecovery, budget *hongguoV5DeviceBudget) ([]byte, hongguoPlaybackRoute, bool, error) {
	state := &downloader.hongguoClient().playbackRoutes
	var plan []hongguoPlaybackRoute
	if recovery.rotated {
		plan = hongguoPlaybackRoutes()
	} else {
		plan = state.Plan(hongguoPlaybackNowMS(), false)
	}
	for _, route := range plan {
		if recovery.skipRoutes[route] {
			continue
		}
		if recovery.attempts >= hongguoV5MaxPlaybackAttempts || ctx.Err() != nil {
			break
		}
		routeParked := state.Parked(route, hongguoPlaybackNowMS())
		var attempt hongguoPlaybackAttempt
		for {
			recovery.attempts++
			attempt = downloader.hongguoV5AttemptDoor(ctx, route, videoID, bodies, budget)
			recovery.allEmpty = recovery.allEmpty && attempt.outcome == hongguoPlaybackAttemptEmpty
			canReprobe := attempt.outcome == hongguoPlaybackAttemptEmpty &&
				!recovery.reprobed && !routeParked &&
				recovery.attempts < hongguoV5MaxPlaybackAttempts &&
				hongguoV5RemainingBudget(ctx) > hongguoV5ReprobeMinBudget
			if canReprobe {
				if err := hongguoSleepContext(ctx, hongguoV5SameDoorReprobeDelay); err != nil {
					return nil, route, false, err
				}
				recovery.reprobed = true
				continue
			}
			break
		}
		recovery.skipRoutes[route] = true
		nowMS := hongguoPlaybackNowMS()
		switch attempt.outcome {
		case hongguoPlaybackAttemptBody:
			return attempt.body, route, true, nil
		case hongguoPlaybackAttemptEmpty:
			state.Failed(route, nowMS, true)
		case hongguoPlaybackAttemptFailed:
			state.Failed(route, nowMS, false)
			if attempt.err != nil {
				recovery.lastErr = attempt.err
			}
		case hongguoPlaybackAttemptDeadline:
			state.Failed(route, nowMS, false)
			return nil, route, false, ctx.Err()
		}
	}
	return nil, hongguoPlaybackRoute{}, false, nil
}

// hongguoV5AttemptDoor: upstream attempt_playback_route — one bounded
// attempt on a single door. The anonymous identity must never become a pool
// pin, so the anon attempt returns no device.
func (downloader *Downloader) hongguoV5AttemptDoor(ctx context.Context, route hongguoPlaybackRoute, videoID string, bodies hongguoV5LadderBodies, budget *hongguoV5DeviceBudget) hongguoPlaybackAttempt {
	switch route.door {
	case hongguoPlaybackDoorAnon:
		return downloader.hongguoV5AttemptAnon(ctx, bodies.anon)
	case hongguoPlaybackDoorV5:
		return downloader.hongguoV5AttemptPost(ctx, hongguoV5PlayerURL, bodies.v5, budget)
	case hongguoPlaybackDoorVideoModel:
		return downloader.hongguoV5AttemptPost(ctx, route.host()+hongguoV5VideoModelPath, bodies.model, budget)
	case hongguoPlaybackDoorVideoTab:
		return downloader.hongguoV5AttemptTab(ctx, route, videoID, budget)
	}
	return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed}
}

// hongguoV5AttemptPost: upstream v5_playback_with_device — one POST door
// with the pooled device. HTTP 401/403 swaps the device (bounded by the
// shared per-request budget); 429/5xx and transport errors retry on the
// same device with re-signing (200ms doubling backoff capped at 5s, at most
// 2 transient retries, Retry-After honoured up to 5s). An empty body
// returns immediately: no device swap, no retry inside the door.
func (downloader *Downloader) hongguoV5AttemptPost(ctx context.Context, base string, body []byte, budget *hongguoV5DeviceBudget) hongguoPlaybackAttempt {
	var lastErr error
	for {
		snapshot := downloader.hongguoCatalogSnapshot()
		identity := hongguoV5Identity{DeviceID: snapshot.DeviceID, InstallID: snapshot.InstallID, CDID: downloader.hongguoCDID()}

		delay := hongguoV5TransientBackoff
		var lastRetryAfter string
		deviceFailed := false
		for transientAttempt := 0; transientAttempt <= hongguoV5TransientRetries; transientAttempt++ {
			if transientAttempt > 0 {
				wait := delay
				delay *= 2
				if delay > hongguoV5RetryAfterCap {
					delay = hongguoV5RetryAfterCap
				}
				if retryAfter := hongguoV5ParseRetryAfter(lastRetryAfter); retryAfter > 0 {
					wait = retryAfter
				}
				if err := hongguoSleepContext(ctx, wait); err != nil {
					return hongguoPlaybackDeadlineAttempt(ctx)
				}
			}
			signed, err := hongguoV5SignPlayback(base, body, identity)
			if err != nil {
				return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: err}
			}
			request, err := http.NewRequestWithContext(ctx, http.MethodPost, signed.URL, bytes.NewReader(body))
			if err != nil {
				return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: err}
			}
			for key, values := range signed.Headers {
				for _, value := range values {
					request.Header.Add(key, value)
				}
			}
			response, err := downloader.hongguoV5Do(request)
			if err != nil {
				if ctx.Err() != nil {
					return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptDeadline}
				}
				lastErr = err
				lastRetryAfter = ""
				continue
			}
			content, readErr := io.ReadAll(io.LimitReader(response.Body, hongguoV5BodyLimit+1))
			response.Body.Close()
			if readErr != nil {
				if ctx.Err() != nil {
					return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptDeadline}
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
				return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: fmt.Errorf("红果 V5 播放接口 HTTP %d", response.StatusCode)}
			case len(bytes.TrimSpace(content)) == 0:
				return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptEmpty}
			case len(content) > hongguoV5BodyLimit:
				return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: errors.New("红果 App 接口未返回有效数据")}
			default:
				return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptBody, body: content}
			}
			if deviceFailed {
				break
			}
		}
		if !deviceFailed {
			return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: lastErr}
		}
		if !budget.takeSwap() {
			return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: fmt.Errorf("红果 V5 播放接口换设备 %d 次后仍失败: %v", hongguoV5DeviceAttempts, lastErr)}
		}
		if err := hongguoSleepContext(ctx, hongguoV5DeviceRetryPause); err != nil {
			return hongguoPlaybackDeadlineAttempt(ctx)
		}
		if err := downloader.reregisterHongguoDevice(ctx); err != nil {
			if ctx.Err() != nil {
				return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptDeadline}
			}
			return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: err}
		}
	}
}

// hongguoV5AttemptTab: the video_tab GET door. Same device policy as the
// POST doors; the response is reshaped before it reaches the parser.
func (downloader *Downloader) hongguoV5AttemptTab(ctx context.Context, route hongguoPlaybackRoute, videoID string, budget *hongguoV5DeviceBudget) hongguoPlaybackAttempt {
	base := route.host() + hongguoV5VideoTabPath
	extra := hongguoV5VideoTabQuery(videoID)
	for {
		snapshot := downloader.hongguoCatalogSnapshot()
		identity := hongguoV5Identity{DeviceID: snapshot.DeviceID, InstallID: snapshot.InstallID, CDID: downloader.hongguoCDID()}

		delay := hongguoV5TransientBackoff
		var lastErr error
		var lastRetryAfter string
		deviceFailed := false
		for transientAttempt := 0; transientAttempt <= hongguoV5TransientRetries; transientAttempt++ {
			if transientAttempt > 0 {
				wait := delay
				delay *= 2
				if delay > hongguoV5RetryAfterCap {
					delay = hongguoV5RetryAfterCap
				}
				if retryAfter := hongguoV5ParseRetryAfter(lastRetryAfter); retryAfter > 0 {
					wait = retryAfter
				}
				if err := hongguoSleepContext(ctx, wait); err != nil {
					return hongguoPlaybackDeadlineAttempt(ctx)
				}
			}
			signed, err := hongguoV5SignPlaybackGet(base, extra, identity)
			if err != nil {
				return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: err}
			}
			request, err := http.NewRequestWithContext(ctx, http.MethodGet, signed.URL, nil)
			if err != nil {
				return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: err}
			}
			for key, values := range signed.Headers {
				for _, value := range values {
					request.Header.Add(key, value)
				}
			}
			response, err := downloader.hongguoV5Do(request)
			if err != nil {
				if ctx.Err() != nil {
					return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptDeadline}
				}
				lastErr = err
				lastRetryAfter = ""
				continue
			}
			content, readErr := io.ReadAll(io.LimitReader(response.Body, hongguoV5BodyLimit+1))
			response.Body.Close()
			if readErr != nil {
				if ctx.Err() != nil {
					return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptDeadline}
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
				return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: fmt.Errorf("红果 V5 播放接口 HTTP %d", response.StatusCode)}
			case len(bytes.TrimSpace(content)) == 0:
				return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptEmpty}
			case len(content) > hongguoV5BodyLimit:
				return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: errors.New("红果 App 接口未返回有效数据")}
			default:
				shaped, ok := hongguoV5VideoTabShape(content)
				if !ok {
					return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: errors.New("红果 video_tab 接口未返回有效数据")}
				}
				return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptBody, body: shaped}
			}
			if deviceFailed {
				break
			}
		}
		if !deviceFailed {
			return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: lastErr}
		}
		if !budget.takeSwap() {
			return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: fmt.Errorf("红果 V5 播放接口换设备 %d 次后仍失败: %v", hongguoV5DeviceAttempts, lastErr)}
		}
		if err := hongguoSleepContext(ctx, hongguoV5DeviceRetryPause); err != nil {
			return hongguoPlaybackDeadlineAttempt(ctx)
		}
		if err := downloader.reregisterHongguoDevice(ctx); err != nil {
			if ctx.Err() != nil {
				return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptDeadline}
			}
			return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: err}
		}
	}
}

// hongguoV5AttemptAnon: upstream anonymous_playback — send once; an empty
// body refreshes the anonymous identity (10-minute throttle) and sends once
// more with the fresh identity.
func (downloader *Downloader) hongguoV5AttemptAnon(ctx context.Context, body []byte) hongguoPlaybackAttempt {
	identity, err := downloader.hongguoAnonCurrent(ctx)
	if err != nil {
		return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: err}
	}
	for send := 0; send < 2; send++ {
		attempt := downloader.hongguoAnonSend(ctx, body, identity.playbackIdentity())
		if attempt.outcome != hongguoPlaybackAttemptEmpty || send == 1 {
			return attempt
		}
		refreshed, err := downloader.hongguoAnonRefreshAfterEmpty(ctx, identity.DeviceID)
		if err != nil || refreshed == nil {
			return attempt
		}
		identity = *refreshed
	}
	return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed}
}

// hongguoAnonSend: one signed anonymous POST against the trailing-slash
// player endpoint.
func (downloader *Downloader) hongguoAnonSend(ctx context.Context, body []byte, identity hongguoAnonV5Identity) hongguoPlaybackAttempt {
	signed, err := hongguoAnonSignPlayback(hongguoAnonPlayerURL, body, identity)
	if err != nil {
		return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: err}
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, signed.URL, bytes.NewReader(body))
	if err != nil {
		return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: err}
	}
	for key, values := range signed.Headers {
		for _, value := range values {
			request.Header.Add(key, value)
		}
	}
	response, err := downloader.hongguoV5Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptDeadline}
		}
		return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed}
	}
	content, readErr := io.ReadAll(io.LimitReader(response.Body, hongguoV5BodyLimit+1))
	response.Body.Close()
	if readErr != nil {
		if ctx.Err() != nil {
			return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptDeadline}
		}
		return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed}
	}
	if response.StatusCode != http.StatusOK {
		return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: fmt.Errorf("红果 V5 播放接口 HTTP %d", response.StatusCode)}
	}
	if len(bytes.TrimSpace(content)) == 0 {
		return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptEmpty}
	}
	if len(content) > hongguoV5BodyLimit {
		return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptFailed, err: errors.New("红果 App 接口未返回有效数据")}
	}
	return hongguoPlaybackAttempt{outcome: hongguoPlaybackAttemptBody, body: content}
}

// hongguoV5RotatePlaybackIdentity: upstream rotate_playback_identity — one
// bounded foreground identity rotation. The pool device re-registers and
// the anonymous identity refreshes; either succeeding counts as a rotation
// (the ladder's first door is the anonymous one, so a fresh anonymous
// identity alone is worth a second pass). The upstream client-side body was
// not in the available diffs; this is the documented judgment call.
func (downloader *Downloader) hongguoV5RotatePlaybackIdentity(ctx context.Context) bool {
	poolOK := downloader.reregisterHongguoDevice(ctx) == nil
	state := downloader.hongguoAnonState()
	state.mu.Lock()
	state.device = nil
	state.expiresAt = time.Time{}
	state.mu.Unlock()
	_, anonErr := downloader.hongguoAnonCurrent(ctx)
	return poolOK || anonErr == nil
}
