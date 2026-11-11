package core

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"moyi/native/core/seku"
)

type Config struct {
	dataDir          string
	MaxPagesPerSort  int
	PageSize         int
	Retries          int
	InsecureTLS      bool
	HuangguoAIURL    string
	HuangguoVideoURL string
	HuangdouURL      string
	HongguoURL       string
	HuangjuURL       string
	HuangjuAPIURL    string
	YeguoURL         string
	YeguoAPIURL      string
	DSDURL           string
	GuipianURL       string
	HanxiaoquanURL   string
	IkanbotURL       string
	A123URL          string
	Token            string
	AESKeyHex        string
	InterfaceKey     string
	ParamKey         string
	ParamIV          string
	APIBase          string
	CDNURL           string
}

type Downloader struct {
	rankings              rankingCache
	cfg                   Config
	client                *http.Client
	huangdouDetails       map[string]huangdouDetailEntry
	huangdouDetailPending map[string]*huangdouDetailCall
	ikanbotLineCache      map[string]ikanbotLineEntry
	ikanbotLinePending    map[string]*ikanbotLineCall
	providerMu            sync.Mutex
	providerHosts         map[string]string
	limiter               *requestLimiter
	proxyRouter           *proxyRouter
	hongguoOnce           sync.Once
	hongguo               *hongguoAppClient
	huangjuOnce           sync.Once
	huangju               *huangjuAPIClient
	yeguoOnce             sync.Once
	yeguo                 *yeguoAPIClient
	dsdCatalog            dsdCatalogState
	diagnostics           *diagnosticLog
	apiMu                 sync.Mutex
	apiBase               string
	apiFailures           map[string]time.Time
	browserTransport      *huangguoBrowserTransport
	legacyOnce            sync.Once
	legacy                *legacyAPIClient
	previewMu             sync.Mutex
	previewSessions       map[string]*huangguoPreviewSession
	shieldMu              sync.Mutex
	shieldClearances      map[string]shieldClearance
	shieldChallenges      map[string]shieldChallenge
}

func defaultConfig() Config { return Config{MaxPagesPerSort: 50, PageSize: 30, Retries: 2} }

type nativeDrama struct {
	MetadataSchema int           `json:"metadataSchema"`
	ID             string        `json:"id"`
	Source         string        `json:"source"`
	SourceID       string        `json:"sourceId"`
	Title          string        `json:"title"`
	Description    string        `json:"description"`
	Cover          string        `json:"cover"`
	Episodes       int           `json:"episodes"`
	Category       string        `json:"category"`
	VIP            *bool         `json:"vip"`
	Heat           string        `json:"heat,omitempty"`
	Views          string        `json:"views,omitempty"`
	OnlineDate     string        `json:"onlineDate,omitempty"`
	Tags           []string      `json:"tags,omitempty"`
	Kind           string        `json:"kind,omitempty"`
	FolderID       string        `json:"folderId,omitempty"`
	Backdrop       string        `json:"backdrop,omitempty"`
	Stills         []string      `json:"stills,omitempty"`
	Related        []nativeDrama `json:"related,omitempty"`
	ReleaseStatus  string        `json:"releaseStatus,omitempty"`
	// Peers 在跨源聚合搜索里带上其它站源的同一部剧，供界面一键切换播放源。
	Peers []nativeDrama `json:"peers,omitempty"`
}

type nativeInput struct {
	LAN              json.RawMessage         `json:"lan"`
	ExpectedVersions map[string]string       `json:"expectedVersions"`
	SystemProxy      nativeSystemProxy       `json:"systemProxy"`
	Settings         nativeResourceSettings  `json:"settings"`
	JobIDs           []string                `json:"jobIds"`
	PlaybackSession  string                  `json:"playbackSession"`
	Cursor           string                  `json:"cursor"`
	SeriesID         string                  `json:"seriesId,omitempty"`
	VideoID          string                  `json:"videoId,omitempty"`
	StartMS          int64                   `json:"startMs"`
	DurationMS       int64                   `json:"durationMs"`
	Board            string                  `json:"board"`
	Entries          []nativeDownloadEpisode `json:"entries"`
	JobID            string                  `json:"jobId"`
	Command          string                  `json:"command"`
	Action           string                  `json:"action"`
	Directory        string                  `json:"directory"`
	Host             string                  `json:"host"`
	Cookie           string                  `json:"cookie"`
	UA               string                  `json:"ua"`
	Source           string                  `json:"source"`
	Sources          []string                `json:"sources"`
	Name             string                  `json:"name"`
	Base             string                  `json:"base"`
	Rule             string                  `json:"rule"`
	Kind             string                  `json:"kind"` // 自定义源类型：web / json / 空=自动
	Content          string                  `json:"content"`
	Page             int                     `json:"page"`
	Query            string                  `json:"query"`
	Category         string                  `json:"category"`
	Filters          map[string]string       `json:"filters"`
	Drama            nativeDrama             `json:"drama"`
	Chapter          Chapter                 `json:"chapter"`
	Index            int                     `json:"index"`
	Quality          int                     `json:"quality"`
	Route            int                     `json:"route"`
	URL              string                  `json:"url"`
	Headers          map[string]string       `json:"headers"`
	ParseAPIs        []string                `json:"parseApis"`
	Session          string                  `json:"session"`
	Sequence         int64                   `json:"sequence"`
	Force            bool                    `json:"force"`
	Flag             string                  `json:"flag,omitempty"`
	PlayID           string                  `json:"playId,omitempty"`
	AdBlock          *bool                   `json:"adBlock"`
	Path             string                  `json:"path"`
	Sha256           string                  `json:"sha256"`
	Manifest         string                  `json:"manifest"`
	Signature        string                  `json:"signature"`
	// 红果账号/登录动作入参（hongguoAccount* / hongguoLogin*）。
	Phone            string                  `json:"phone"`
	Code             string                  `json:"code"`
	Token            string                  `json:"token"`
	AccountCookie    string                  `json:"accountCookie"`
	AccountID        string                  `json:"accountId"`
	UserName         string                  `json:"userName"`
	ExpiresAtMS      int64                   `json:"expiresAtMs"`
	CookieSource     string                  `json:"cookieSource"`
	DeviceID         string                  `json:"deviceId"`
	InstallID        string                  `json:"installId"`
	Online           *bool                   `json:"online"`
	Add              *bool                   `json:"add"`
	ItemID           string                  `json:"itemId"`
	EpisodeIndex     int                     `json:"episodeIndex"`
	EpisodeCount     int                     `json:"episodeCount"`
	ProgressMS       int64                   `json:"progressMs"`
	TotalMS          int64                   `json:"totalMs"`
	UpdatedAtMS      int64                   `json:"updatedAtMs"`
}

type nativeFilterOption struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type nativeFilterGroup struct {
	Key     string               `json:"key"`
	Name    string               `json:"name"`
	Options []nativeFilterOption `json:"options"`
}

type nativeCatalogResult struct {
	Items       []nativeDrama       `json:"items"`
	HasMore     bool                `json:"hasMore"`
	Page        int                 `json:"page"`
	Warning     string              `json:"warning,omitempty"`
	LocalSearch bool                `json:"localSearch"`
	Fresh       bool                `json:"fresh"`
	Filters     []nativeFilterGroup `json:"filters,omitempty"`
	hongguo     *hongguoCatalogState
	saveError   error
}

type nativePlan struct {
	ExpiresAt       int64             `json:"expiresAt,omitempty"`
	PrefetchedBytes int64             `json:"prefetchedBytes,omitempty"`
	DanmakuID       string            `json:"danmakuId,omitempty"`
	Local           bool              `json:"local"`
	URL             string            `json:"url"`
	OriginalURL     string            `json:"originalUrl,omitempty"`
	Headers         map[string]string `json:"headers"`
	Key             string            `json:"decryptionKey,omitempty"`
	Quality         int               `json:"quality"`
	Qualities       []int             `json:"qualities"`
	Session         string            `json:"session,omitempty"`
	RouteIndex      int               `json:"routeIndex"`
	RouteCount      int               `json:"routeCount"`
	Parse           bool              `json:"parse,omitempty"`
}

func nativeParseFallbackPlan(pageURL, referer string) nativePlan {
	headers := map[string]string{}
	if referer != "" {
		headers["Referer"] = referer
	}
	return nativePlan{URL: pageURL, OriginalURL: pageURL, Headers: headers, Parse: true, RouteCount: 1}
}

type nativeEngine struct {
	lanMu            sync.Mutex
	lan              *nativeLANServer
	settingsMu       sync.Mutex
	settings         nativeResourceSettings
	readMu           sync.Mutex
	reads            map[string]nativeReadRequest
	readCount        int
	work             map[string]bool
	downloads        *nativeDownloads
	downloader       *Downloader
	directory        string
	mu               sync.Mutex
	catalogs         map[string][]nativeDrama
	catalogStates    map[string]nativeCatalogState
	categoryOptions  map[string][]nativeCategory
	hongguoCatalog   *hongguoCatalogState
	recommendations  map[string]nativeRecommendationState
	catalogSaveError error
	sourceSaveError  error
	covers           *nativeCoverCache
	stream           *nativeStreamServer
	playbacks        map[string]nativePlaybackChoice
	playbackMu       sync.Mutex
	playbackSequence int64
	playbackCancel   context.CancelFunc
	sourceTasks      map[string]*nativeSourceTask
	sourceRecords    map[string]nativeSourceRecord
	sourceCatalogMu  sync.Mutex
	sourceCatalogs   map[string]chan struct{}
	customRegistry   *customMaccmsRegistry
}

var nativeState struct {
	sync.Mutex
	engine *nativeEngine
}

func nativeText(value any) string {
	switch v := value.(type) {
	case string:
		return strings.TrimSpace(v)
	case map[string]any:
		for _, key := range []string{"url", "src", "cover", "image", "pic"} {
			if text := nativeText(v[key]); text != "" {
				return text
			}
		}
	case []any:
		for _, entry := range v {
			if text := nativeText(entry); text != "" {
				return text
			}
		}
	case json.Number:
		return string(v)
	case float64:
		return strconv.Itoa(int(v))
	case int:
		return strconv.Itoa(v)
	}
	return ""
}

func nativeNormalize(drama Drama) nativeDrama {
	cover := ""
	for _, value := range []any{drama.Cover, drama.CoverURL, drama.CoverURLSnake, drama.Image, drama.ImageURL, drama.ImageURLSnake, drama.Img, drama.Pic, drama.Picture, drama.Poster, drama.Thumb, drama.Thumbnail} {
		candidate := nativeText(value)
		if strings.HasPrefix(candidate, "//") {
			candidate = "https:" + candidate
		}
		if isProviderHTTPMediaURL(candidate) {
			cover = candidate
			break
		}
	}
	episodes := 0
	for _, value := range []any{drama.TotalEpisode, drama.TotalEpisodeSnake, drama.EpisodeCount, drama.EpisodeCountSnake, drama.ChapterCount, drama.ChapterCountSnake, drama.Total, drama.Episodes} {
		if count, _ := strconv.Atoi(nativeText(value)); count > episodes {
			episodes = count
		}
	}
	source, sourceID, _ := splitProviderDramaID(drama.ID)
	normalized := nativeDrama{MetadataSchema: 1, ID: drama.ID, Source: source, SourceID: sourceID, Title: drama.DisplayTitle(),
		Description: firstNonEmpty(drama.Desc, drama.Intro), Cover: cover, Episodes: episodes,
		Category: nativeDramaCategory(drama), VIP: drama.VIP,
		Heat: drama.Heat, Views: drama.Views, OnlineDate: providerReleaseDate(drama.OnlineDate),
		Tags: append([]string(nil), drama.Tags...), ReleaseStatus: drama.ReleaseStatus,
		Kind: drama.Kind, FolderID: drama.FolderID, Backdrop: drama.Backdrop,
		Stills: append([]string(nil), drama.Stills...)}
	for _, related := range drama.Related {
		related.Related = nil
		normalized.Related = append(normalized.Related, nativeNormalize(related))
	}
	return normalized
}

func nativeDramaCategory(drama Drama) string {
	category := firstNonEmpty(drama.CategoryName, drama.CategoryNameSnake, drama.TypeName, drama.TypeNameSnake, drama.SortName, drama.SortNameSnake, drama.Category)
	if category != "" {
		return category
	}
	switch drama.ChannelName {
	case "真人剧", "短剧", "漫剧", "AI 剧", "AI剧", "AI 短剧", "AI 漫剧", "AI 换脸", "AI 魔改":
		return drama.ChannelName
	}
	return ""
}

func newNativeEngine(directory string) (*nativeEngine, error) {
	if !filepath.IsAbs(directory) {
		return nil, errors.New("应用数据目录无效")
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	cfg := defaultConfig()
	cfg.dataDir = directory
	router := &proxyRouter{}
	d := &Downloader{cfg: cfg, providerHosts: map[string]string{}, proxyRouter: router,
		limiter: newRequestLimiter(3, 250*time.Millisecond), diagnostics: newDiagnosticLog(directory)}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	// RootCAs 设为「系统信任库 + 打包 CA 全集」。Android 端 Go 不加载系统信任库，
	// 打包 CA 在此提供信任锚（含 Certum 等小众公共根），从而修复 m3u8 等媒体请求的
	// "certificate signed by unknown authority"。其余平台行为不变。
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: systemCertPoolWithBundle()}
	transport.MaxIdleConnsPerHost = 8
	transport.ResponseHeaderTimeout = 20 * time.Second
	transport.Proxy = router.proxy
	cdn := newCDNTransport(transport, newDNSResolver(transport))
	browserTransport := newHuangguoBrowserTransport(cdn, d)
	d.browserTransport = browserTransport
	d.client = &http.Client{Transport: browserTransport, Timeout: 45 * time.Second,
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return errors.New("站源重定向次数过多")
			}
			if len(via) > 0 && !strings.EqualFold(request.URL.Host, via[0].URL.Host) {
				request.Header.Del("X-Preview-Token")
			}
			return nil
		}}
	engine := &nativeEngine{downloader: d, directory: directory, catalogs: map[string][]nativeDrama{}, catalogStates: map[string]nativeCatalogState{}}
	d.loadShieldClearances()
	engine.loadResourceSettings()
	d.loadRankingCache()
	engine.loadCatalogCache()
	// 自定义源注册表必须先于 sources.json 加载：
	// loadSourceRecords 里的 isHuangguoProviderSource 要能认出 custom:<hash> 记录才不会丢任务状态。
	engine.customRegistry = newCustomMaccmsRegistry(directory)
	engine.customRegistry.load()
	// 已存在的自定义源（含 Cloudflare 前缀加速源）也要登记进浏览器指纹传输白名单，
	// 与运行时新增/更新路径一致，保证重启后其目录/页面请求仍走 Chrome 150 指纹。
	for _, record := range engine.customMaccmsSources() {
		engine.registerCustomBrowserHost(record.Base)
	}
	engine.loadSourceRecords()
	engine.covers = newNativeCoverCache(directory, d)
	engine.downloads = newNativeDownloads(engine)
	return engine, nil
}

func NativeRequest(raw string) (result string) {
	defer func() {
		if recover() != nil {
			result = `{"ok":false,"error":"本地核心处理失败，请重试"}`
		}
	}()
	var input nativeInput
	if len(raw) > 1<<20 || json.Unmarshal([]byte(raw), &input) != nil {
		return `{"ok":false,"error":"请求格式无效"}`
	}
	data, err := nativeDispatch(input)
	envelope := map[string]any{"ok": err == nil}
	if err != nil {
		envelope["error"] = publicError(err).Error()
		if errors.Is(err, errNativeLocalFile) {
			envelope["code"] = "local_media"
		}
		var backoff *requestBackoff
		if errors.As(err, &backoff) {
			envelope["code"] = "source_blocked"
			envelope["retryAt"] = backoff.until
		}
		source := canonicalProviderSource(input.Source)
		if source == "" {
			source = sourceFromDramaID(input.Drama.ID)
		}
		if !errors.Is(err, context.Canceled) && (input.Action == "catalog" || input.Action == "detail" || input.Action == "resolve") {
			nativeState.Lock()
			engine := nativeState.engine
			nativeState.Unlock()
			if engine != nil && nativeSourceAvailable(source) {
				engine.changeSourceRecord(source, func(record *nativeSourceRecord) {
					record.Error = publicError(err).Error()
					if backoff != nil {
						record.RetryAt = backoff.until
					}
					if !record.Running {
						record.Stage, record.FinishedAt = "访问失败", time.Now()
					}
				})
			}
		}
	} else {
		envelope["data"] = data
	}
	body, marshalErr := json.Marshal(envelope)
	if marshalErr != nil {
		return `{"ok":false,"error":"无法读取站源返回的数据"}`
	}
	return string(body)
}

func nativeDispatch(input nativeInput) (any, error) {
	if err := nativeAuthorizeInput(input); err != nil {
		return nil, err
	}
	switch input.Action {
	case "coreInfo":
		return coreInfoData(), nil
	case "legadoRun":
		out, err := LegadoRunJSON(input.Content, input.Category, input.Query)
		if err != nil {
			return nil, err
		}
		var raw json.RawMessage = []byte(out)
		return map[string]any{"result": raw}, nil
	case "jsSpider":
		out, err := jsSpiderDispatch(input)
		if err != nil {
			return nil, err
		}
		return map[string]any{"result": out}, nil
	}
	nativeState.Lock()
	if input.Action == "initialize" {
		if nativeState.engine == nil {
			// newNativeEngine 内部会经 isHuangguoProviderSource 读取全局引擎（自定义源判定），
			// 持锁创建会自死锁；先解锁创建，再上锁安装，并发 initialize 时以先装上的引擎为准。
			nativeState.Unlock()
			engine, err := newNativeEngine(input.Directory)
			nativeState.Lock()
			if err != nil {
				nativeState.Unlock()
				return nil, err
			}
			if nativeState.engine == nil {
				nativeState.engine = engine
			}
		}
		nativeState.Unlock()
		return map[string]any{"version": "0.2.19", "standalone": true, "allSources": buildAllSources == "true", "coreBuild": coreBuildNumber()}, nil
	}
	engine := nativeState.engine
	nativeState.Unlock()
	if engine == nil {
		return nil, errors.New("应用核心尚未就绪，请重新打开应用")
	}
	duration := 60 * time.Second
	if input.Action == "moveDownloads" {
		duration = 10 * time.Minute
	} else if input.Action == "danmaku" || input.Action == "comments" || input.Action == "hongguoDanmakuById" || input.Action == "hongguoCommentsById" {
		duration = 10 * time.Second
	} else if input.Action == "preload" {
		duration = 15 * time.Second
	} else if input.Action == "searchAcross" {
		// 跨源搜索要并发打多个站源，单站 25s 超时，整体放宽到 3 分钟。
		duration = 3 * time.Minute
	}
	ctx, cancel := context.WithTimeout(context.Background(), duration)
	defer cancel()
	if input.Action == "danmaku" || input.Action == "comments" || input.Action == "hongguoDanmakuById" || input.Action == "hongguoCommentsById" || input.Action == "preload" || input.Action == "prepareHandoff" || input.Session != "" && (input.Action == "catalog" || input.Action == "categories" || input.Action == "suggestions" || input.Action == "recommendations" || input.Action == "metadata") {
		work, finish, err := engine.beginRead(ctx, input)
		if err != nil {
			return nil, err
		}
		defer finish()
		ctx = work
	}
	switch input.Action {
	case "lan":
		return engine.nativeLAN(ctx, input.Command, input.LAN)
	case "clearanceNeeded":
		return map[string]any{"items": engine.downloader.pendingShieldChallenges(), "userAgent": shieldUserAgent}, nil
	case "setClearance":
		return true, engine.downloader.setShieldClearance(input.Host, input.Cookie, input.UA)
	case "updateSystemProxy":
		return true, engine.updateSystemProxy(input.SystemProxy)
	case "crackConfigSet":
		removed, err := seku.CrackConfigSet(input.Content)
		if err != nil {
			return nil, err
		}
		for _, host := range removed {
			engine.downloader.removeShieldClearance(host)
		}
		for _, m := range seku.CrackDownloaderMappings() {
			_ = engine.downloader.setShieldClearance(m.Host, m.Cookie, m.UA)
		}
		return seku.CrackConfigSummary(), nil
	case "crackConfigSummary":
		return seku.CrackConfigSummary(), nil
	case "resourceSettings":
		return engine.resourceSettings(), nil
	case "saveResourceSettings":
		return engine.saveResourceSettings(input.Settings)
	case "controlDownloadBatch":
		return engine.downloads.controlBatchExpected(ctx, input.JobIDs, input.Command, input.ExpectedVersions)
	case "preload":
		return engine.nativePreload(ctx, input)
	case "prepareHandoff":
		return engine.nativeResolve(ctx, input)
	case "danmaku":
		return engine.nativeDanmaku(ctx, input)
	case "comments":
		return engine.nativeComments(ctx, input)
	case "hongguoDanmakuById":
		return engine.downloader.hongguoDanmaku(ctx, input.SeriesID, input.VideoID, input.StartMS, input.DurationMS)
	case "hongguoCommentsById":
		return engine.downloader.hongguoComments(ctx, input.SeriesID, input.Cursor)
	case "cancelRead":
		engine.cancelRead(input)
		return true, nil
	case "recommendations":
		return engine.nativeRecommendations(ctx, input)
	case "cachedRecommendations":
		return engine.cachedRecommendations(input.Category)
	case "rankingBoards":
		boards := []rankingBoard{}
		for _, board := range rankingBoards {
			if nativeSourceAvailable(board.Source) {
				boards = append(boards, board)
			}
		}
		return map[string]any{"items": boards}, nil
	case "rankings":
		return engine.nativeRanking(ctx, input)
	case "suggestions":
		items, err := engine.suggestions(ctx, input.Query)
		return map[string]any{"items": items}, err
	case "downloadDirectory":
		engine.downloads.mu.Lock()
		root := engine.downloads.root
		engine.downloads.mu.Unlock()
		return map[string]string{"directory": root}, nil
	case "downloadRemuxDirectory":
		directory, err := engine.downloads.remuxDirectory(input.JobID)
		if err != nil {
			return nil, err
		}
		return map[string]string{"directory": directory}, nil
	case "storage":
		return engine.storage()
	case "moveDownloads":
		return true, engine.moveDownloads(ctx, input.Directory)
	case "workLease":
		count, err := engine.workLease(input.JobID, input.Command)
		return map[string]int{"count": count}, err
	case "downloads":
		jobs, err := engine.downloads.snapshot()
		return map[string]any{"jobs": jobs}, err
	case "enqueueDownloads":
		added, err := engine.downloads.enqueueContext(ctx, input)
		return map[string]int{"added": added}, err
	case "controlDownloads":
		return true, engine.downloads.control(input.JobID, input.Command)
	case "localPlayback":
		plan, _, err := engine.downloads.localPlan(input.Drama.ID, input.Index)
		return plan, err
	case "catalog":
		return engine.nativeCatalog(ctx, input)
	case "searchAcross":
		return engine.nativeSearchAcross(ctx, input)
	case "cached":
		if !validNativeCategory(canonicalProviderSource(input.Source), input.Category) {
			return nil, errors.New("内容分类无效")
		}
		return engine.nativeCached(nativeCatalogKey(input.Source, input.Category)), nil
	case "categories":
		items, err := engine.nativeCategories(ctx, input.Source, input.Force)
		return map[string]any{"items": items}, err
	case "sourceStatus":
		return engine.sourceStatus(input.Source), nil
	case "hongguoDeviceStatus":
		return engine.downloader.hongguoDeviceStatus(), nil
	case "hongguoDeviceRegister":
		if err := engine.downloader.ensureHongguoDevice(ctx, ""); err != nil {
			return nil, err
		}
		return engine.downloader.hongguoDeviceStatus(), nil
	case "hongguoDeviceReregister":
		if err := engine.downloader.reregisterHongguoDevice(ctx); err != nil {
			return nil, err
		}
		return engine.downloader.hongguoDeviceStatus(), nil
	case "hongguoDeviceRefresh":
		changed, err := engine.downloader.refreshHongguoDevice(ctx)
		if err != nil {
			return nil, err
		}
		status := engine.downloader.hongguoDeviceStatus()
		status["changed"] = changed
		return status, nil
	case "hongguoAccountStatus":
		return engine.downloader.hongguoAccountStatus(), nil
	case "hongguoAccountSetSession":
		expires := time.Time{}
		if input.ExpiresAtMS > 0 {
			expires = time.UnixMilli(input.ExpiresAtMS)
		}
		engine.downloader.setHongguoAccountSession(hongguoAccountSession{
			Cookie: input.AccountCookie, DeviceID: input.DeviceID, InstallID: input.InstallID,
			AccountID: input.AccountID, UserName: input.UserName,
			ExpiresAt: expires, Source: input.CookieSource,
		})
		return engine.downloader.hongguoAccountStatus(), nil
	case "hongguoAccountExportSession":
		return engine.downloader.hongguoAccountExportSession(), nil
	case "hongguoAccountClearSession":
		engine.downloader.setHongguoAccountSession(hongguoAccountSession{})
		return engine.downloader.hongguoAccountStatus(), nil
	case "hongguoLoginQr":
		image, expires, err := engine.downloader.hongguoLoginQR(ctx)
		if err != nil {
			return nil, err
		}
		return map[string]any{"imageBase64": image, "expiresSeconds": expires}, nil
	case "hongguoLoginQrPoll":
		loggedIn, err := engine.downloader.hongguoLoginQRPoll(ctx)
		if err != nil {
			return nil, err
		}
		status := engine.downloader.hongguoAccountStatus()
		status["loggedIn"] = loggedIn
		return status, nil
	case "hongguoAccountInfo":
		return engine.downloader.hongguoLoginAccountInfo(ctx)
	case "hongguoLoginSendCode":
		masked, retry, err := engine.downloader.hongguoLoginWebSendCode(ctx, input.Phone)
		if err != nil {
			return nil, err
		}
		return map[string]any{"maskedMobile": masked, "retrySeconds": retry}, nil
	case "hongguoLoginSms":
		return engine.downloader.hongguoLoginWebVerify(ctx, input.Phone, input.Code)
	case "hongguoLoginAppSendCode":
		masked, retry, err := engine.downloader.hongguoLoginAppSendCode(ctx, input.Phone)
		if err != nil {
			return nil, err
		}
		return map[string]any{"maskedMobile": masked, "retrySeconds": retry}, nil
	case "hongguoLoginAppSms":
		return engine.downloader.hongguoLoginAppVerify(ctx, input.Phone, input.Code)
	case "hongguoAccountFavorites":
		items, err := engine.downloader.hongguoAccountFavorites(ctx)
		if err != nil {
			return nil, err
		}
		return map[string]any{"items": items}, nil
	case "hongguoAccountSetFavorite":
		add := input.Add != nil && *input.Add
		items, err := engine.downloader.hongguoAccountSetFavorite(ctx, input.SeriesID, add)
		if err != nil {
			return nil, err
		}
		return map[string]any{"items": items}, nil
	case "hongguoAccountHistory":
		items, err := engine.downloader.hongguoAccountHistory(ctx)
		if err != nil {
			return nil, err
		}
		return map[string]any{"items": items}, nil
	case "hongguoAccountUploadProgress":
		progress := hongguoCloudProgress{
			SeriesID: input.SeriesID, EpisodeID: input.ItemID,
			EpisodeIndex: input.EpisodeIndex, EpisodeCount: input.EpisodeCount,
			PositionMS: input.ProgressMS, DurationMS: input.TotalMS,
			UpdatedAtMS: input.UpdatedAtMS,
		}
		if err := engine.downloader.hongguoAccountUploadProgress(ctx, progress); err != nil {
			return nil, err
		}
		return map[string]any{"ok": true}, nil
	case "hongguoAccountReservations":
		online := input.Online != nil && *input.Online
		items, err := engine.downloader.hongguoAccountReservations(ctx, online)
		if err != nil {
			return nil, err
		}
		return map[string]any{"items": items}, nil
	case "hongguoAccountReserve":
		if err := engine.downloader.hongguoAccountReserve(ctx, input.SeriesID); err != nil {
			return nil, err
		}
		return map[string]any{"ok": true}, nil
	case "hongguoAccountRelated":
		items, err := engine.downloader.hongguoAccountRelated(ctx, input.SeriesID)
		if err != nil {
			return nil, err
		}
		return map[string]any{"items": items}, nil
	case "hongguoAccountFilter":
		return engine.downloader.hongguoAccountFilter(ctx, input.Content, input.Cursor)
	case "sourceJob":
		return engine.startSourceTask(input.Source, input.Command, input.Drama)
	case "cancelSourceJob":
		return engine.cancelSourceTask(input.Source), nil
	case "customSources":
		return map[string]any{"items": engine.customMaccmsSources()}, nil
	case "addCustomSource":
		record, err := engine.addCustomMaccmsSource(input.Name, input.Base, input.Rule, input.Kind)
		if err != nil {
			return nil, err
		}
		return record, nil
	case "updateCustomSource":
		record, err := engine.updateCustomMaccmsSource(input.Source, input.Name, input.Base, input.Rule, input.Kind)
		if err != nil {
			return nil, err
		}
		return record, nil
	case "removeCustomSource":
		return true, engine.removeCustomMaccmsSource(input.Source)
	case "exportCustomSources":
		content, err := engine.exportCustomMaccmsSources()
		if err != nil {
			return nil, err
		}
		return map[string]any{"content": content, "filename": customSourceExportFilename()}, nil
	case "importCustomSources":
		if strings.TrimSpace(input.Content) == "" {
			return nil, errors.New("导入内容为空")
		}
		result, err := engine.importCustomMaccmsSources(input.Content)
		if err != nil {
			return nil, err
		}
		return result, nil
	case "resetCustomSources":
		removed, err := engine.resetCustomMaccmsSources()
		if err != nil {
			return nil, err
		}
		return map[string]any{"removed": removed}, nil
	case "customRuleValidate":
		name, base, kind, err := validateCustomMaccmsInput(input.Name, input.Base, input.Rule, input.Kind)
		if err != nil {
			return nil, err
		}
		return map[string]string{"name": name, "base": base, "kind": kind}, nil
	case "customRulePreview":
		items, err := engine.previewCustomMaccmsRule(ctx, input.Name, input.Base, input.Rule, input.Kind)
		if err != nil {
			return nil, err
		}
		return map[string]any{"items": items}, nil
	case "cover":
		return engine.loadCover(ctx, input.Drama, input.Force)
	case "prepareCover":
		return engine.prepareCover(ctx, input.Drama)
	case "detail":
		return engine.nativeDetail(ctx, input.Drama)
	case "metadata":
		return engine.nativeMetadata(ctx, input.Drama)
	case "hongguoRefresh":
		rotated, err := engine.downloader.refreshHongguoDevice(ctx)
		if err != nil {
			return nil, err
		}
		return map[string]any{"rotated": rotated}, nil
	case "resolve", "fallback":
		playback, finish, err := engine.nativeBeginPlayback(ctx, input.Sequence)
		if err != nil {
			return nil, err
		}
		defer finish()
		if input.Action == "fallback" {
			return engine.nativeNextPlayback(playback, input.Session)
		}
		return engine.nativeResolve(playback, input)
	case "selectRoute":
		playback, finish, err := engine.nativeBeginPlayback(ctx, input.Sequence)
		if err != nil {
			return nil, err
		}
		defer finish()
		return engine.nativeSelectRoute(playback, input.Session, input.Route)
	case "resolveParse":
		return engine.nativeResolveParse(ctx, input)
	case "cancelPlayback":
		engine.nativeCancelPlayback(input.Sequence)
		return true, nil
	case "release":
		engine.nativeReleasePlayback(input.Session)
		return true, nil
	default:
		return nil, errors.New("不支持的应用操作")
	}
}

func (engine *nativeEngine) nativeCatalog(ctx context.Context, input nativeInput) (nativeCatalogResult, error) {
	source := canonicalProviderSource(input.Source)
	if !isHuangguoProviderSource(source) {
		return nativeCatalogResult{}, errors.New("请选择有效站源")
	}
	category := strings.TrimSpace(input.Category)
	if !validNativeCategory(source, category) {
		return nativeCatalogResult{}, errors.New("内容分类无效")
	}
	cacheKey := nativeCatalogKey(source, category)
	if err := ctx.Err(); err != nil {
		return nativeCatalogResult{}, err
	}
	page := max(1, input.Page)
	query := strings.TrimSpace(input.Query)
	if query == "" {
		if retried, err := engine.retryCatalogSave(); retried {
			cached := engine.nativeCached(cacheKey)
			if shouldUseRetryCache(err, len(cached.Items)) {
				return cached, nil
			}
			if err != nil {
				return nativeCatalogResult{}, err
			}
		}
	}
	// 实时抓取口径：目录一律现抓现显，不再因本地缓存未过期（Fresh）
	// 而跳过站源请求。缓存只由 Dart 侧 cached 动作作首屏占位，
	// 并由 saveCatalogCache 回写供下次占位与站源计数使用。
	d := engine.downloader
	result := nativeCatalogResult{Items: []nativeDrama{}, Page: page}
	if query != "" {
		return engine.nativeSearchSource(ctx, source, query, page)
	}
	unlock, lockErr := engine.lockSourceCatalog(ctx, source)
	if lockErr != nil {
		return nativeCatalogResult{}, lockErr
	}
	defer unlock()
	if err := ctx.Err(); err != nil {
		return result, err
	}
	var items []Drama
	var err error
	switch source {
	case sourceHGTV:
		items, result.HasMore, result.Filters, err = d.fetchHGTVCatalogPage(ctx, category, page, input.Filters)
	case sourceHGTVMirror:
		items, result.HasMore, result.Filters, err = d.fetchHGTVMirrorCatalogPage(ctx, category, page)
	case sourceHongguo:
		if hongguoIsBookCategory(category) {
			if category == "novel" {
				if ncat := input.Filters["ncat"]; ncat != "" && hongguoBookCategoryName(ncat) != "" {
					items, result.Filters, result.HasMore, err = d.fetchHongguoBookCategoryCatalog(ctx, ncat, "", input.Filters["nstatus"], input.Filters["nsort"], page)
				} else {
					items, _, err = d.fetchHongguoBookmallCatalog(ctx, 2, "", 3)
					result.Filters = hongguoNovelFilterGroups()
					result.HasMore = false
				}
			} else if category == "audio" {
				items, result.Filters, err = d.fetchHongguoBookmallCatalog(ctx, 5, input.Filters["category"], 4)
				result.HasMore = false
			} else {
				catID := strings.TrimPrefix(category, "bcat")
				items, result.Filters, result.HasMore, err = d.fetchHongguoBookCategoryCatalog(ctx, catID, input.Filters["sub"], input.Filters["status"], input.Filters["sort"], page)
			}
			break
		}
		engine.mu.Lock()
		known := make(map[string]bool, len(engine.catalogs[cacheKey]))
		for _, drama := range engine.catalogs[cacheKey] {
			known[drama.ID] = true
		}
		engine.mu.Unlock()
		ctx = context.WithValue(ctx, libraryKnownKey{}, known)
		if page > 1 {
			ctx = context.WithValue(ctx, libraryMoreKey{}, true)
		}
		items, err = d.fetchHongguoAppCatalogCategory(ctx, category)
		if err == nil {
			result.Filters = hongguoShortDramaFilterGroups()
			items = hongguoFilterShortDramas(items, input.Filters)
		}
		state := d.hongguoCatalogSnapshot()
		result.hongguo = state
		result.HasMore = hongguoCatalogHasMore(state)
		if category != "" && state != nil {
			result.HasMore = !state.Feeds["category:"+category].Exhausted
		}
		if len(items) == 0 && err != nil && ctx.Err() == nil && (category == "" || category == "short_play") {
			var totalPages int
			items, totalPages, err = d.fetchHongguoCategoryPage(ctx, "real-drama?page="+strconv.Itoa(page), "真人剧")
			result.HasMore = page < totalPages
		}
	case sourceHuangdou:
		client := newHuangdouAPIClient(d)
		var decoded any
		err = client.call(ctx, "/drama/list", map[string]any{"page": strconv.Itoa(page), "page_size": "30"}, &decoded)
		if err == nil {
			rows := huangdouList(decoded)
			for _, row := range rows {
				if drama := huangdouDramaFromMap(row); drama.ID != "" {
					items = append(items, drama)
				}
			}
			result.HasMore = len(rows) >= 30
		}
	case sourceHuangguoAI:
		items, result.HasMore, err = d.fetchHuangguoAICatalogPage(ctx, page, category)
	case sourceHuangju:
		items, result.HasMore, err = d.fetchHuangjuCatalogPage(ctx, page, category, "")
	case sourceYeguo:
		items, result.HasMore, err = d.fetchYeguoCatalogPage(ctx, page, category, "")
	case sourceDSD:
		items, result.HasMore, err = d.fetchDSDCatalogPage(ctx, page, category, "")
	case sourceGuipian:
		items, result.HasMore, err = d.fetchGuipianCatalogPage(ctx, page, category, "")
	case sourceHanxiaoquan:
		items, result.HasMore, err = d.fetchHanxiaoquanCatalogPage(ctx, page, category, "")
	case sourceIkanbot:
		items, result.HasMore, err = d.fetchIkanbotCatalogPage(ctx, page, category, "")
	case sourceA123:
		items, result.HasMore, err = d.fetchA123CatalogPage(ctx, page, category, "")
	case sourceHuangguoVideo:
		address := fmt.Sprintf("%s/videos?page=%d", d.providerBaseURL(source), page)
		if category != "" {
			address += "&category=" + url.QueryEscape(category)
		}
		var body string
		body, err = d.fetchProviderText(ctx, address, d.providerBaseURL(source)+"/")
		if err == nil {
			items = parseHuangguoVideoCards(body, address)
		}
		result.HasMore = len(items) >= 20
	case sourceCloudFront:
		items, result.HasMore, err = d.fetchLegacyCatalogCategoryPage(ctx, page, category)
	default:
		if isSekuSource(source) {
			seku.Init(engine.directory)
			items, result.HasMore, err = d.fetchSekuCatalogPageFiltered(ctx, source, page, category, input.Filters)
			if err == nil && source == "youtube" {
				result.Filters = youtubeFilterGroups(category)
			}
		} else if isDuanjuProviderSource(source) {
			items, result.HasMore, err = d.fetchDuanjuCatalogPage(ctx, source, page, category)
		}
	}
	if !providerSupportsFilters(source) {
		result.Filters = nil
	}
	if err != nil && len(items) == 0 {
		return result, err
	}
	if len(items) == 0 && page == 1 && source != sourceHuangju && source != sourceYeguo && source != sourceDSD && source != sourceGuipian && source != sourceHanxiaoquan && source != sourceIkanbot && source != sourceA123 && !isDuanjuProviderSource(source) && !isSekuSource(source) {
		return result, errors.New("站源暂未返回剧集，请稍后刷新")
	}
	if err != nil {
		result.Warning = publicError(err).Error()
	}
	seen := map[string]bool{}
	for _, drama := range items {
		if drama.ID == "" || seen[drama.ID] {
			continue
		}
		seen[drama.ID] = true
		result.Items = append(result.Items, nativeNormalize(drama))
	}
	// saveCatalogCache 会把本地库旧条目并回 result（供 sourceJob 建库与
	// 下次占位），但请求路径必须只呈现本次实时抓到的条目与分页状态，
	// 故回写后恢复实时结果；保存失败产生的 warning/saveError 保留。
	liveItems, livePage, liveHasMore, liveWarning := result.Items, result.Page, result.HasMore, result.Warning
	engine.saveCatalogCache(cacheKey, &result)
	result.Items, result.Page = liveItems, livePage
	if liveWarning == "" {
		result.HasMore = liveHasMore
	}
	return result, nil
}

func (engine *nativeEngine) nativeDetail(ctx context.Context, drama nativeDrama) (any, error) {
	source, sourceID, valid := splitProviderDramaID(drama.ID)
	if !valid {
		return nil, errors.New("剧集信息无效，请刷新剧库")
	}
	if isSekuSource(source) {
		return engine.nativeSekuDetail(ctx, drama, source, sourceID)
	}
	var title string
	var raw Drama
	var chapters []Chapter
	var err error
	switch source {
	case sourceHongguo:
		if strings.HasPrefix(sourceID, "audio:") {
			raw, chapters, err = engine.downloader.fetchHongguoAudioDetailHongguo(ctx, strings.TrimPrefix(sourceID, "audio:"))
			break
		}
		if strings.HasPrefix(sourceID, "novel:") {
			raw, chapters, err = engine.downloader.fetchHongguoNovelDetail(ctx, strings.TrimPrefix(sourceID, "novel:"))
			break
		}
		title, chapters, err = engine.downloader.GetHuangguoChapters(ctx, source, sourceID)
		if err == nil {
			raw = Drama{Title: title, Name: title}
		}
	case sourceHGTV:
		raw, chapters, err = engine.downloader.fetchHGTVDetail(ctx, sourceID)
	case sourceHGTVMirror:
		raw, chapters, err = engine.downloader.fetchHGTVMirrorDetail(ctx, sourceID)
	case sourceHuangguoAI:
		raw, chapters, err = engine.downloader.fetchHuangguoAIDetail(ctx, sourceID)
	case sourceHuangguoVideo:
		raw, chapters, err = engine.downloader.fetchHuangguoVideoDetail(ctx, sourceID)
	case sourceCloudFront:
		raw, chapters, err = engine.downloader.fetchLegacyDetail(ctx, sourceID)
	case sourceHuangju:
		raw, chapters, err = engine.downloader.fetchHuangjuDetail(ctx, sourceID)
	case sourceYeguo:
		raw, chapters, err = engine.downloader.fetchYeguoDetail(ctx, sourceID)
	case sourceDSD:
		raw, chapters, err = engine.downloader.fetchDSDDetail(ctx, sourceID)
	case sourceGuipian:
		raw, chapters, err = engine.downloader.fetchGuipianDetail(ctx, sourceID)
	case sourceHanxiaoquan:
		raw, chapters, err = engine.downloader.fetchHanxiaoquanDetail(ctx, sourceID)
	case sourceIkanbot:
		raw, chapters, err = engine.downloader.fetchIkanbotDetail(ctx, sourceID)
	case sourceA123:
		raw, chapters, err = engine.downloader.fetchA123Detail(ctx, sourceID)
	default:
		if isDuanjuProviderSource(source) {
			raw, chapters, err = engine.downloader.fetchDuanjuDetail(ctx, source, sourceID)
			break
		}
		title, chapters, err = engine.downloader.GetHuangguoChapters(ctx, source, sourceID)
	}
	if err != nil {
		return nil, err
	}
	if len(chapters) == 0 {
		return nil, errors.New("该剧暂时没有可播放的分集")
	}
	if title != "" && title != "短剧" {
		drama.Title = title
	}
	if raw.ID == drama.ID {
		drama = mergeNativeDrama(drama, nativeNormalize(raw))
	}
	if source == sourceHongguo {
		raw := engine.downloader.hongguoCachedDrama(Drama{ID: drama.ID, Title: drama.Title, Source: source})
		drama = mergeNativeDrama(drama, nativeNormalize(raw))
	}
	if source == sourceHuangdou {
		if row, err := engine.downloader.huangdouDetail(ctx, sourceID); err == nil {
			fresh := nativeNormalize(huangdouDramaFromMap(row))
			if fresh.ID == drama.ID {
				drama = mergeNativeDrama(drama, fresh)
			}
		}
	}
	drama.Source, drama.SourceID, drama.Episodes = source, sourceID, len(chapters)
	if source == sourceHuangju || source == sourceYeguo {
		drama.Episodes = max(drama.Episodes, nativeNormalize(raw).Episodes)
	}
	warning := ""
	if err := engine.saveDetailMetadata(drama); err != nil {
		warning = err.Error()
	}
	return map[string]any{"drama": drama, "chapters": chapters, "warning": warning}, nil
}

func (engine *nativeEngine) nativeResolve(ctx context.Context, input nativeInput) (nativePlan, error) {
	if _, _, valid := splitProviderDramaID(input.Drama.ID); !valid {
		return nativePlan{}, errors.New("剧集信息无效")
	}
	if !input.Force && engine.downloads != nil {
		if plan, found, err := engine.downloads.localPlan(input.Drama.ID, input.Index); found || err != nil {
			if input.Action != "prepareHandoff" || !errors.Is(err, errNativeLocalFile) {
				return plan, err
			}
		}
	}
	task := Task{DramaID: input.Drama.ID, DramaTitle: input.Drama.Title, Chapter: input.Chapter, Index: input.Index}
	media, err := engine.downloader.resolveProviderMedia(ctx, task)
	if err != nil {
		return nativePlan{}, err
	}
	if strings.HasPrefix(media.URL, "novel://") {
		headers := map[string]string{}
		if media.Referer != "" {
			headers["Referer"] = media.Referer
		}
		return nativePlan{URL: media.URL, OriginalURL: input.Chapter.VideoURL, Headers: headers, RouteCount: 1}, nil
	}
	choice := nativePlaybackChoices(media, input.Quality)
	if series, video, valid := hongguoPlaybackIDs(task); valid {
		choice.danmakuSeries, choice.danmakuVideo = series, video
	}
	// 去广告开关：请求未显式给出时默认开启。
	choice.adBlock = input.AdBlock == nil || *input.AdBlock
	choice.index = nativePreferredRoute(input.Route, len(choice.media))
	if choice.index >= 0 && choice.index < len(choice.media) && choice.media[choice.index].NeedsParse {
		pageURL := choice.media[choice.index].URL
		referer := choice.media[choice.index].Referer
		if len(input.ParseAPIs) == 0 {
			return nativeParseFallbackPlan(pageURL, referer), nil
		}
		real, parsedHeaders, err := resolveViaParseAPIs(ctx, pageURL, referer, input.ParseAPIs)
		if err != nil {
			return nativeParseFallbackPlan(pageURL, referer), nil
		}
		if h := parsedHeaders["Referer"]; h != "" {
			referer = h
		} else if h := parsedHeaders["referer"]; h != "" {
			referer = h
		}
		choice.media[choice.index].URL = real
		choice.media[choice.index].Referer = referer
		choice.media[choice.index].NeedsParse = false
		plan, err := engine.nativeOpenPlayback(ctx, choice)
		if err != nil {
			return nativePlan{}, err
		}
		plan.OriginalURL = pageURL
		return plan, nil
	}
	return engine.nativeOpenPlayback(ctx, choice)
}
