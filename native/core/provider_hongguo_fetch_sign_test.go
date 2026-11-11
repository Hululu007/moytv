package core

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestHongguoSixGodBranchRange(t *testing.T) {
	now := time.Unix(1760000000, 0)
	for offset := int64(0); offset < 8; offset++ {
		query := "aid=8662&device_id=123&_rticket=" + strconv.FormatInt(now.UnixMilli()+offset, 10)
		branch := hongguoSixGodBranch(query, []byte(`{"a":1}`), uint32(now.Unix()))
		if branch < 0 || branch > 2 {
			t.Fatalf("branch out of range: %d", branch)
		}
	}
}

func TestHongguoPickBranchZeroTicket(t *testing.T) {
	now := time.Unix(1760000000, 0)
	request, err := http.NewRequest(http.MethodGet, "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/video_tab/multi_video_model/v1/", nil)
	if err != nil {
		t.Fatal(err)
	}
	query := url.Values{"aid": {"8662"}, "device_id": {"12345678901"}}
	ticket := hongguoPickBranchZeroTicket(request, query, nil, now, false)
	if ticket < now.UnixMilli() || ticket >= now.UnixMilli()+128 {
		t.Fatalf("ticket out of range: %d", ticket)
	}
	if got := request.URL.Query().Get("_rticket"); got != strconv.FormatInt(ticket, 10) {
		t.Fatalf("_rticket mismatch: %s vs %d", got, ticket)
	}
	if branch := hongguoSixGodBranch(request.URL.RawQuery, nil, uint32(now.Unix())); branch != 0 {
		t.Fatalf("picked ticket must give branch 0, got %d", branch)
	}
	// 通用形态同时带 ts 查询参数。
	generic, err := http.NewRequest(http.MethodGet, "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/search/tab/v", nil)
	if err != nil {
		t.Fatal(err)
	}
	hongguoPickBranchZeroTicket(generic, query, nil, now, true)
	if generic.URL.Query().Get("ts") != strconv.FormatInt(now.Unix(), 10) {
		t.Fatalf("generic form must carry ts, got %q", generic.URL.Query().Get("ts"))
	}
}

func TestHongguoPlayerSignForms(t *testing.T) {
	now := time.Unix(1760000000, 0)
	build := func() *http.Request {
		request, err := http.NewRequest(http.MethodPost, "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/?aid=8662&device_id=12345678901&_rticket=1760000000000", strings.NewReader(`{}`))
		if err != nil {
			t.Fatal(err)
		}
		return request
	}
	playback := build()
	signHongguoPlayerRequestFull(playback, []byte(`{}`), now, now.UnixMilli(), true, "")
	if playback.Header.Get("X-TT-Store-Region") != "cn" || playback.Header.Get("X-TT-Store-Region-Src") != "did" {
		t.Fatal("playback form must carry region headers")
	}
	if playback.Header.Get("X-TT-Request-Tag") != "" || playback.Header.Get("Passport-Sdk-Version") != "" {
		t.Fatal("playback form must not carry request-tag/passport headers")
	}
	if playback.Header.Get("X-Gorgon") == "" || playback.Header.Get("X-Medusa") == "" || playback.Header.Get("X-Argus") == "" {
		t.Fatal("playback form must carry gorgon/medusa/argus headers")
	}
	generic := build()
	signHongguoPlayerRequestFull(generic, []byte(`{}`), now, now.UnixMilli(), false, "")
	if generic.Header.Get("X-TT-Request-Tag") != "t=0;n=0" || generic.Header.Get("Passport-Sdk-Version") != "50561" {
		t.Fatal("generic form must carry request-tag/passport headers")
	}
	if generic.Header.Get("X-TT-Store-Region") != "" {
		t.Fatal("generic form must not carry region headers")
	}
	if generic.Header.Get("X-Vc-Bdturing-Sdk-Version") != "3.7.2.cn" {
		t.Fatal("generic form with body must carry bdturing header")
	}
}

func TestHongguoMedusaProcessFixed(t *testing.T) {
	launch1, pid1 := sixGodProcessFixed()
	launch2, pid2 := sixGodProcessFixed()
	if launch1 != launch2 || pid1 != pid2 {
		t.Fatal("process-fixed medusa values must be stable within the process")
	}
	if launch1 == 0 || pid1 == 0 {
		t.Fatal("process-fixed medusa values must be non-zero")
	}
}

func TestHongguoDeviceRejected(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Path, "device_register") {
			return sourceFixtureResponse(request, http.StatusOK, `{"device_id_str":"1001","install_id_str":"10019"}`), nil
		}
		return sourceFixtureResponse(request, http.StatusOK, `{"code":110001,"data":{}}`), nil
	})
	d.cfg.Retries = 1
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	_, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if !errors.Is(err, errHongguoDeviceRejected) {
		t.Fatalf("110001 must surface as device-rejected, got %v", err)
	}
	if state := d.hongguoCatalogSnapshot(); state.DeviceID == "7" {
		t.Fatal("device-rejected must rotate the device before giving up")
	}
}

func TestHongguoPrefetchCacheTakeDeletes(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, http.StatusOK, `{}`), nil
	})
	model := map[string]any{"video_list": []any{map[string]any{
		"main_url":   "https://media.example.test/high.mp4",
		"video_meta": map[string]any{"codec_type": "h264", "definition": "1080p"},
	}}}
	d.hongguoOfferUpcomingModel("12346", model)
	taken, ok := d.hongguoTakeUpcomingModel("12346")
	if !ok || len(taken) == 0 {
		t.Fatal("offered model must be takeable once")
	}
	if _, ok := d.hongguoTakeUpcomingModel("12346"); ok {
		t.Fatal("prefetch cache must delete on take")
	}
}

func TestHongguoMultiModelPrefetch(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Path, "video_tab") {
			return sourceFixtureResponse(request, http.StatusOK, ``), nil
		}
		body := `{"code":0,"data":{
			"12345":{"video_model":{"video_list":[{"main_url":"https://media.example.test/high.mp4","video_meta":{"codec_type":"h264","definition":"1080p"}}],"video_duration":"60"}},
			"12346":{"video_model":{"video_list":[{"main_url":"https://media.example.test/next.mp4","video_meta":{"codec_type":"h264","definition":"720p"}}],"video_duration":"60"}}
		}}`
		return sourceFixtureResponse(request, http.StatusOK, body), nil
	})
	d.cfg.Retries = 1
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	media, err := d.resolveHongguoMultiModelWithUpcoming(context.Background(), "12345", []string{"12346"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(media.URL, "high.mp4") {
		t.Fatalf("current episode must resolve, got %q", media.URL)
	}
	taken, ok := d.hongguoTakeUpcomingModel("12346")
	if !ok {
		t.Fatal("next episode model must enter the prefetch cache")
	}
	selected, err := selectHongguoAppMedia(taken)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(selected.URL, "next.mp4") {
		t.Fatalf("cached next episode must resolve, got %q", selected.URL)
	}
}

func TestHongguoVideoTabModel(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Query().Get("video_id") != "12345" || request.URL.Query().Get("video_platform") != "1024" {
			t.Errorf("GET leg must carry video_id/video_platform, got %q", request.URL.RawQuery)
		}
		body := `{"code":0,"data":{"video_model_data":{"12345":{"video_model":{"video_list":[{"main_url":"https://media.example.test/tab1080.mp4","video_meta":{"codec_type":"h264","definition":"1080p"}}],"video_duration":"60"}}}}}`
		return sourceFixtureResponse(request, http.StatusOK, body), nil
	})
	d.cfg.Retries = 1
	media, err := d.resolveHongguoVideoTabModel(context.Background(), "12345")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(media.URL, "tab1080.mp4") {
		t.Fatalf("GET leg must resolve, got %q", media.URL)
	}
}

func TestHongguoRouteCooling(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, http.StatusOK, `{}`), nil
	})
	client := d.hongguoClient()
	key := hongguoRouteKey(http.MethodGet, hongguoAppBaseURL, "/reading/bookapi/video_tab/multi_video_model/v1/")
	if d.hongguoRouteCooling(key) {
		t.Fatal("fresh route must not be cooling")
	}
	client.hongguoNoteRouteFailure(key, true)
	if !d.hongguoRouteCooling(key) {
		t.Fatal("empty response must cool the route for 30s")
	}
	client.hongguoNoteRouteSuccess(key)
	if d.hongguoRouteCooling(key) {
		t.Fatal("success must clear route cooling")
	}
	if d.hongguoRouteLastSuccess(key).IsZero() {
		t.Fatal("success must record last-success time")
	}
}

func TestHongguoCookieSession(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, http.StatusOK, `{}`), nil
	})
	client := d.hongguoClient()
	resp := &http.Response{Header: http.Header{}}
	resp.Header.Add("Set-Cookie", "sessionid=abc123; Path=/")
	resp.Header.Add("Set-Cookie", "ttwid=xyz; Path=/")
	client.mu.Lock()
	client.hongguoStoreCookies("api5-normal-sinfonlineb.fqnovel.com", resp)
	header := client.hongguoCookieHeader("api5-normal-sinfonlineb.fqnovel.com")
	client.mu.Unlock()
	if !strings.Contains(header, "sessionid=abc123") || !strings.Contains(header, "ttwid=xyz") {
		t.Fatalf("cookie jar must round-trip, got %q", header)
	}
	if got := client.hongguoCookieHeader("other.example.test"); got != "" {
		t.Fatalf("cookies must be host-scoped, got %q", got)
	}
}

func TestHongguoCompatReread(t *testing.T) {
	model := map[string]any{
		"fallback_api": "https://fallback.example.test/api",
		"video_list": []any{map[string]any{
			"main_url":   "https://media.example.test/bytevc2.mp4",
			"video_meta": map[string]any{"codec_type": "bytevc2", "definition": "1080p"},
		}},
	}
	if got := hongguoModelCompatibleCount(model); got != 0 {
		t.Fatalf("all-bytevc2 model must count 0 compatible rows, got %d", got)
	}
	var fetched []string
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		fetched = append(fetched, request.URL.String())
		if request.URL.Query().Get("force_codec") == "h264" {
			return sourceFixtureResponse(request, http.StatusOK, `{"video_info":{"data":{"video_list":[{"main_url":"https://media.example.test/compat720.mp4","video_meta":{"codec_type":"h264","definition":"720p"}}]}}}`), nil
		}
		return sourceFixtureResponse(request, http.StatusOK, `{"video_info":{"data":{"video_list":[{"main_url":"https://media.example.test/bytevc2b.mp4","video_meta":{"codec_type":"bytevc2","definition":"1080p"}}]}}}`), nil
	})
	d.hongguoMergeFallbackAPI(context.Background(), model)
	if len(fetched) != 2 {
		t.Fatalf("compat reread must fire a second fetch, got %d: %v", len(fetched), fetched)
	}
	if !strings.Contains(fetched[1], "codec_type=0") || !strings.Contains(fetched[1], "force_codec=h264") {
		t.Fatalf("compat reread must carry codec params, got %q", fetched[1])
	}
	if got := hongguoModelCompatibleCount(model); got == 0 {
		t.Fatal("compat reread must add a compatible row")
	}
	selected, err := selectHongguoAppMedia(model)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(selected.URL, "compat720.mp4") {
		t.Fatalf("compat row must be selected, got %q", selected.URL)
	}
}

func TestHongguoAccountNotLoggedIn(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, http.StatusOK, `{}`), nil
	})
	if _, err := d.hongguoAccountFavorites(context.Background()); !errors.Is(err, errHongguoAccountNotLoggedIn) {
		t.Fatalf("account calls without login must fail fast, got %v", err)
	}
	if _, err := d.hongguoAccountHistory(context.Background()); !errors.Is(err, errHongguoAccountNotLoggedIn) {
		t.Fatalf("history without login must fail fast, got %v", err)
	}
}

func TestHongguoAccountParsers(t *testing.T) {
	favorites, err := parseHongguoAccountFavorites(map[string]any{
		"data": map[string]any{"video_shelf_info": []any{map[string]any{
			"series_id": "7701", "series_title": "测试剧", "series_cover_url": "https://cover.example.test/1.jpg",
			"video_data": map[string]any{"episode_cnt": float64(30)},
		}}},
	})
	if err != nil || len(favorites) != 1 || favorites[0].SeriesID != "7701" || favorites[0].Badge != "全 30 集" {
		t.Fatalf("favorites parse failed: %+v err=%v", favorites, err)
	}
	history := parseHongguoAccountHistory([]any{map[string]any{
		"series_id": "7701", "vid": "8801", "vid_index": float64(3),
		"current_play_time": float64(120), "current_total_time": float64(600),
		"last_watch_time": float64(1760000000), "episode_count": float64(30),
	}})
	if len(history) != 1 || history[0].EpisodeIndex != 2 || history[0].PositionMS != 120000 || history[0].UpdatedAtMS != 1760000000000 {
		t.Fatalf("history parse failed: %+v", history)
	}
	reservations, err := parseHongguoAccountReservations(map[string]any{
		"data": map[string]any{"subscribe_items": []any{
			map[string]any{"series_id": "7702", "series_title": "已上线剧", "subscribe_data": map[string]any{"episode_cnt": float64(10)}},
			map[string]any{"item_id": "9901", "subscribe_data": map[string]any{"series_title": "待上线剧"}},
		}},
	}, false)
	if err != nil || len(reservations) != 2 {
		t.Fatalf("reservations parse failed: %+v err=%v", reservations, err)
	}
	if reservations[1].SeriesID != "reservation:9901" {
		t.Fatalf("unpublished reservation must be namespaced, got %q", reservations[1].SeriesID)
	}
	related := parseHongguoAccountRelated(map[string]any{
		"data": []any{map[string]any{
			"show_type": float64(547), "video_data": []any{
				map[string]any{"series_id": "7703", "title": "第二季", "content_type": float64(1004), "episode_cnt": float64(20), "season_index": float64(2), "cover": "https://cover.example.test/2.jpg"},
				map[string]any{"series_id": "7704", "title": "第三季", "content_type": float64(1007), "season_index": float64(3)},
			},
		}},
	}, "7701")
	if len(related) != 2 || !related[1].Upcoming || related[0].SeasonIndex != 2 {
		t.Fatalf("related parse failed: %+v", related)
	}
}

func TestHongguoMixParamAndMobile(t *testing.T) {
	if got := hongguoMixParam("13800138000"); got != "34363d353534363d353535" {
		t.Fatalf("mix param mismatch: %q", got)
	}
	if got := hongguoMixParam("24"); got != "3731" {
		t.Fatalf("mix type mismatch: %q", got)
	}
	mobile, err := hongguoFormatMobile("86", "138-0013-8000")
	if err != nil || mobile != "13800138000" {
		t.Fatalf("mobile format failed: %q err=%v", mobile, err)
	}
	if _, err := hongguoFormatMobile("86", "2800138000"); err == nil {
		t.Fatal("non-1-prefixed mainland number must fail")
	}
}

func TestHongguoWebSendCodeRequest(t *testing.T) {
	var seenMethod, seenBody, seenCSRF string
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		seenMethod = request.Method
		seenCSRF = request.Header.Get("X-Tt-Passport-Csrf-Token")
		raw, _ := io.ReadAll(request.Body)
		seenBody = string(raw)
		return sourceFixtureResponse(request, http.StatusOK, `{"message":"success","data":{"mobile":"138****8000","retry_time":60}}`), nil
	})
	client := d.hongguoClient()
	client.mu.Lock()
	if client.cookies == nil {
		client.cookies = map[string]map[string]string{}
	}
	client.cookies["hongguoduanju.com"] = map[string]string{"passport_csrf_token": "csrf1"}
	client.mu.Unlock()
	masked, retry, err := d.hongguoLoginWebSendCode(context.Background(), "13800138000")
	if err != nil {
		t.Fatal(err)
	}
	if masked != "138****8000" || retry != 60 {
		t.Fatalf("send_code parse failed: %q %d", masked, retry)
	}
	if seenMethod != http.MethodPost || seenCSRF != "csrf1" {
		t.Fatalf("send_code must POST with csrf header, got %s csrf=%q", seenMethod, seenCSRF)
	}
	if !strings.Contains(seenBody, "mobile=2e3d332534363d353534363d353535") || !strings.Contains(seenBody, "type=3731") {
		t.Fatalf("send_code body must carry mixed params, got %q", seenBody)
	}
}

func TestHongguoAppSendCodeRequest(t *testing.T) {
	var seenQuery url.Values
	var seenBody string
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		seenQuery = request.URL.Query()
		raw, _ := io.ReadAll(request.Body)
		seenBody = string(raw)
		resp := sourceFixtureResponse(request, http.StatusOK, `{"message":"success","data":{"mobile":"138****8000","retry_time":60,"mobile_ticket":"ticket1"}}`)
		resp.Header.Set("Set-Cookie", "sessionid=app1; Path=/")
		return resp, nil
	})
	d.cfg.Retries = 1
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "12345678901", "12345678902", true
	masked, retry, err := d.hongguoLoginAppSendCode(context.Background(), "13800138000")
	if err != nil {
		t.Fatal(err)
	}
	if masked != "138****8000" || retry != 60 {
		t.Fatalf("app send_code parse failed: %q %d", masked, retry)
	}
	if seenQuery.Get("device_id") != "" || seenQuery.Get("iid") != "" {
		t.Fatalf("app passport query must not carry device_id/iid, got %q", seenQuery.Encode())
	}
	if seenQuery.Get("mobile") != "13800138000" || seenQuery.Get("type") != "24" {
		t.Fatalf("app send_code query must carry mobile/type, got %q", seenQuery.Encode())
	}
	if seenBody != "" {
		t.Fatalf("app send_code (form=false) must be a GET with no body, got %q", seenBody)
	}
	if got := hongguoClientCookie(client, "security.snssdk.com", "sessionid"); got != "app1" {
		t.Fatalf("app send_code must collect Set-Cookie, got %q", got)
	}
}

func TestHongguoSignFormRouting(t *testing.T) {
	if got := hongguoSignFormForPath("/novel/player/multi_video_model/v1/", true); got != hongguoSignPlayback {
		t.Fatal("player paths must use playback form")
	}
	if got := hongguoSignFormForPath("/reading/bookapi/video_tab/multi_video_model/v1/", true); got != hongguoSignPlayback {
		t.Fatal("video_tab paths must use playback form")
	}
	if got := hongguoSignFormForPath("/reading/bookapi/search/tab/v", true); got != hongguoSignGeneric {
		t.Fatal("search must use generic form")
	}
	if got := hongguoSignFormForPath("/reading/bookapi/bookmall/tab/v1/", false); got != hongguoSignNone {
		t.Fatal("bookmall tab without identity must stay unsigned")
	}
	if got := hongguoSignFormForPath("/reading/bookapi/bookmall/tab/v1/", true); got != hongguoSignPlayback {
		t.Fatal("bookmall tab with identity must use playback form")
	}
}
