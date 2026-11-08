package core

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"moyi/native/core/seku"
)

type nativeStreamAsset struct {
	address     string
	data        []byte
	contentType string
	total       int64
	etag        string
	modified    string
	cenc        *cencPrepared
}

type nativeStreamSession struct {
	credentials *providerMediaCredentials
	mu          sync.Mutex
	assets      map[string]nativeStreamAsset
	referer     string
	key         []byte
	ctx         context.Context
	cancel      context.CancelFunc
	lastUsed    time.Time
	adBlock     bool
	order       []string
	warmMu      sync.Mutex
	warming     map[string]bool
	hook        seku.StreamHook
}

// nativeWarmAheadLimit 是单个分片预取的上限，超出则不缓存（避免内存无谓增长）。
const nativeWarmAheadLimit = 12 << 20

const nativeStreamIdleTimeout = 30 * time.Second

const nativeShortRefetchBytes = 300

const nativeShortRefetchCap = 32 << 20

type nativeIdleTimeoutReader struct {
	reader io.Reader
	idle   time.Duration
}

func (r *nativeIdleTimeoutReader) Read(p []byte) (int, error) {
	type result struct {
		n   int
		err error
	}
	buf := make([]byte, len(p))
	ch := make(chan result, 1)
	go func() {
		n, err := r.reader.Read(buf)
		ch <- result{n, err}
	}()
	select {
	case res := <-ch:
		copy(p, buf[:res.n])
		return res.n, res.err
	case <-time.After(r.idle):
		return 0, errors.New("读取媒体超时")
	}
}

type nativeStreamServer struct {
	mu                 sync.Mutex
	downloader         *Downloader
	address            string
	passthroughAddress string
	sessions           map[string]*nativeStreamSession
	server             *http.Server
	passthroughServer  *http.Server
}

func (stream *nativeStreamServer) nativeRequest(request *http.Request) (*http.Response, error) {
	client := *stream.downloader.client
	client.Timeout = 0
	return stream.downloader.doMediaRequestWithClient(request, &client)
}

var nativePlaylistURI = regexp.MustCompile(`URI="([^"]+)"`)

func newNativeStreamServer(d *Downloader) (*nativeStreamServer, error) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, errors.New("无法初始化本机播放器")
	}
	passthroughListener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		listener.Close()
		return nil, errors.New("无法初始化本机播放器")
	}
	stream := &nativeStreamServer{downloader: d, address: "http://" + listener.Addr().String(), passthroughAddress: "http://" + passthroughListener.Addr().String(), sessions: map[string]*nativeStreamSession{}}
	server := &http.Server{Handler: http.HandlerFunc(stream.nativeServeRewrite), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16384}
	stream.server = server
	go func() { _ = server.Serve(listener) }()
	passthroughServer := &http.Server{Handler: http.HandlerFunc(stream.nativeServePassthrough), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16384}
	stream.passthroughServer = passthroughServer
	go func() { _ = passthroughServer.Serve(passthroughListener) }()
	return stream, nil
}

func (stream *nativeStreamServer) nativeOpen(media providerMedia, adBlock bool) (string, string) {
	tokenBytes := make([]byte, 24)
	if _, err := rand.Read(tokenBytes); err != nil {
		panic(err)
	}
	token := hex.EncodeToString(tokenBytes)
	ctx, cancel := context.WithCancel(providerMediaContext(context.Background(), media.credentials))
	session := &nativeStreamSession{assets: map[string]nativeStreamAsset{}, warming: map[string]bool{}, referer: media.Referer, key: media.HLSKey, ctx: ctx, cancel: cancel, lastUsed: time.Now(), credentials: media.credentials, adBlock: adBlock, hook: media.Hook}
	stream.mu.Lock()
	for id, old := range stream.sessions {
		if time.Since(old.lastUsed) > 10*time.Minute {
			old.cancel()
			delete(stream.sessions, id)
		}
	}
	if len(stream.sessions) >= 8 {
		oldest := ""
		for id, old := range stream.sessions {
			if oldest == "" || old.lastUsed.Before(stream.sessions[oldest].lastUsed) {
				oldest = id
			}
		}
		stream.sessions[oldest].cancel()
		delete(stream.sessions, oldest)
	}
	stream.sessions[token] = session
	stream.mu.Unlock()
	entry := nativeStreamAsset{address: media.URL, contentType: "video/mp4"}
	if media.Audio {
		entry.contentType = "audio/mp4"
	}
	if parsed, err := url.Parse(media.URL); err == nil && strings.HasSuffix(strings.ToLower(parsed.Path), ".m3u8") {
		entry.contentType = "application/vnd.apple.mpegurl"
	}
	if media.Playlist != "" {
		entry.data = []byte(media.Playlist)
		if strings.Contains(media.Playlist, "<MPD") {
			entry.contentType = "application/dash+xml"
		} else {
			entry.contentType = "application/vnd.apple.mpegurl"
		}
	}
	if len(media.CENCKey) == 16 && (entry.contentType == "video/mp4" || entry.contentType == "audio/mp4") {
		fetcher := func(ctx context.Context, start, end int64) ([]byte, int64, error) {
			return stream.nativeFetchRange(ctx, session, media.URL, start, end)
		}
		if prepared, err := cencSetup(session.ctx, media.CENCKey, fetcher); err == nil {
			entry.cenc = prepared
		}
	}
	return stream.nativeAsset(token, session, entry), token
}

func (stream *nativeStreamServer) nativeRelease(token string) {
	stream.mu.Lock()
	if session := stream.sessions[token]; session != nil {
		session.cancel()
		delete(stream.sessions, token)
	}
	stream.mu.Unlock()
}

func (stream *nativeStreamServer) nativeAsset(token string, session *nativeStreamSession, asset nativeStreamAsset) string {
	digest := sha256.Sum256([]byte(asset.address + "\x00" + asset.contentType))
	extension := ".ts"
	if parsed, err := url.Parse(asset.address); err == nil {
		switch candidate := strings.ToLower(path.Ext(parsed.Path)); candidate {
		case ".m3u8", ".ts", ".m4s", ".mp4", ".aac", ".m4a", ".mp3", ".vtt", ".webvtt", ".key", ".mpd":
			extension = candidate
		}
	}
	switch asset.contentType {
	case "application/vnd.apple.mpegurl":
		extension = ".m3u8"
	case "application/dash+xml":
		extension = ".mpd"
	case "application/octet-stream":
		extension = ".key"
	case "video/mp4", "audio/mp4":
		extension = ".mp4"
	}
	id := hex.EncodeToString(digest[:12]) + extension
	session.mu.Lock()
	if previous, found := session.assets[id]; !found || len(previous.data) == 0 || len(asset.data) > 0 {
		session.assets[id] = asset
	}
	session.mu.Unlock()
	base := stream.passthroughAddress
	if strings.Contains(asset.contentType, "mpegurl") {
		base = stream.address
	}
	return base + "/" + token + "/" + id
}

func (stream *nativeStreamServer) nativeAssetID(line, token string) string {
	for _, base := range []string{stream.address, stream.passthroughAddress} {
		if id := strings.TrimPrefix(line, base+"/"+token+"/"); id != line && id != "" {
			return id
		}
	}
	return ""
}

func (stream *nativeStreamServer) nativeRewrite(token string, session *nativeStreamSession, body, base string) (string, error) {
	var output []string
	var order []string
	nextPlaylist := false
	for _, line := range strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n") {
		text := strings.TrimSpace(line)
		rewrite := func(reference string, key bool, contentType string) string {
			if strings.HasPrefix(reference, "data:") {
				return reference
			}
			parsed, err := url.Parse(base)
			if err != nil {
				return ""
			}
			relative, err := url.Parse(reference)
			if err != nil {
				return ""
			}
			address := parsed.ResolveReference(relative).String()
			if !isProviderHTTPMediaURL(address) {
				return ""
			}
			asset := nativeStreamAsset{address: address, contentType: contentType}
			if key && len(session.key) == 16 {
				asset.data = append([]byte{}, session.key...)
				asset.contentType = "application/octet-stream"
			}
			return stream.nativeAsset(token, session, asset)
		}
		if text != "" && !strings.HasPrefix(text, "#") {
			contentType := ""
			if nextPlaylist {
				contentType = "application/vnd.apple.mpegurl"
			}
			line = rewrite(text, false, contentType)
			nextPlaylist = false
			if line == "" {
				return "", errors.New("播放列表中的媒体地址无效")
			}
			// 记录媒体分片的先后顺序，供播放中按序预取后续分片。
			if contentType == "" {
				if id := stream.nativeAssetID(line, token); id != "" {
					order = append(order, id)
				}
			}
		} else if strings.Contains(text, "URI=") {
			invalid := false
			line = nativePlaylistURI.ReplaceAllStringFunc(line, func(match string) string {
				reference := nativePlaylistURI.FindStringSubmatch(match)[1]
				key := strings.HasPrefix(text, "#EXT-X-KEY:") || strings.HasPrefix(text, "#EXT-X-SESSION-KEY:")
				contentType := ""
				switch {
				case key:
					contentType = "application/octet-stream"
				case strings.HasPrefix(text, "#EXT-X-MAP:"):
					contentType = "video/mp4"
				case strings.HasPrefix(text, "#EXT-X-MEDIA:"), strings.HasPrefix(text, "#EXT-X-I-FRAME-STREAM-INF:"), strings.HasPrefix(text, "#EXT-X-RENDITION-REPORT:"):
					contentType = "application/vnd.apple.mpegurl"
				}
				updated := rewrite(reference, key, contentType)
				if updated == "" {
					invalid = true
				}
				return "URI=\"" + updated + "\""
			})
			if invalid {
				return "", errors.New("播放列表中的附属地址无效")
			}
		}
		if strings.HasPrefix(text, "#EXT-X-STREAM-INF:") {
			nextPlaylist = true
		}
		output = append(output, line)
	}
	if len(order) > 0 {
		session.mu.Lock()
		session.order = order
		session.mu.Unlock()
	}
	return strings.Join(output, "\n"), nil
}

// nativeWarmAhead 在播放到某个分片时预取其后的若干分片。
//
// nativePrefetch 只在开播时预热一次，预热缓冲放完后每个分片都要现取，
// 上游延迟会在分片边界处表现为周期性的轻微卡顿；这里补充播放中的顺序预取。
func (stream *nativeStreamServer) nativeWarmAhead(session *nativeStreamSession, token, currentID string) {
	session.warmMu.Lock()
	index := -1
	for i, id := range session.order {
		if id == currentID {
			index = i
			break
		}
	}
	if index < 0 {
		session.warmMu.Unlock()
		return
	}
	var targets []string
	for i := index + 1; i < len(session.order) && len(targets) < 2; i++ {
		id := session.order[i]
		if session.warming[id] {
			continue
		}
		session.mu.Lock()
		asset, ok := session.assets[id]
		session.mu.Unlock()
		if ok && len(asset.data) > 0 {
			continue
		}
		session.warming[id] = true
		targets = append(targets, id)
	}
	session.warmMu.Unlock()
	for _, id := range targets {
		go stream.nativeWarmSegment(session, id)
	}
}

// nativeWarmSegment 后台取回单个分片并写入会话，使播放器请求时可直接命中缓存。
func (stream *nativeStreamServer) nativeWarmSegment(session *nativeStreamSession, id string) {
	defer func() {
		session.warmMu.Lock()
		delete(session.warming, id)
		session.warmMu.Unlock()
	}()
	session.mu.Lock()
	asset, ok := session.assets[id]
	session.mu.Unlock()
	if !ok || len(asset.data) > 0 || strings.Contains(asset.contentType, "mpegurl") {
		return
	}
	ctx, cancel := context.WithCancel(providerMediaContext(session.ctx, session.credentials))
	defer cancel()
	stop := context.AfterFunc(session.ctx, cancel)
	defer stop()
	fetchAddress := asset.address
	if session.hook != nil {
		signed, err := session.hook.SignSegment(fetchAddress)
		if err != nil {
			return
		}
		fetchAddress = signed
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, fetchAddress, nil)
	if err != nil {
		return
	}
	request.Header.Set("User-Agent", userAgent)
	request.Header.Set("Referer", session.referer)
	response, err := stream.downloader.doMediaRequest(request)
	if err != nil {
		return
	}
	defer response.Body.Close()
	// 只接受完整响应：部分响应会在播放时触发范围请求，交给主路径处理更稳妥。
	if response.StatusCode != http.StatusOK {
		return
	}
	body, err := io.ReadAll(io.LimitReader(&nativeIdleTimeoutReader{reader: response.Body, idle: nativeStreamIdleTimeout}, nativeWarmAheadLimit+1))
	if err != nil || len(body) == 0 || int64(len(body)) > nativeWarmAheadLimit {
		return
	}
	asset.data = body
	asset.total = int64(len(body))
	asset.etag, asset.modified = response.Header.Get("ETag"), response.Header.Get("Last-Modified")
	if response.Request != nil && response.Request.URL != nil {
		asset.address = response.Request.URL.String()
	}
	session.mu.Lock()
	session.assets[id] = asset
	session.mu.Unlock()
}

func (stream *nativeStreamServer) nativeServeRewrite(writer http.ResponseWriter, request *http.Request) {
	stream.nativeServe(writer, request, true)
}

func (stream *nativeStreamServer) nativeServePassthrough(writer http.ResponseWriter, request *http.Request) {
	stream.nativeServe(writer, request, false)
}

func (stream *nativeStreamServer) nativeServe(writer http.ResponseWriter, request *http.Request, rewriteOnly bool) {
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	parts := strings.Split(strings.Trim(request.URL.Path, "/"), "/")
	if len(parts) != 2 {
		http.NotFound(writer, request)
		return
	}
	stream.mu.Lock()
	session := stream.sessions[parts[0]]
	if session != nil {
		session.lastUsed = time.Now()
	}
	stream.mu.Unlock()
	if session == nil {
		http.Error(writer, "播放已结束", http.StatusGone)
		return
	}
	session.mu.Lock()
	asset, found := session.assets[parts[1]]
	session.mu.Unlock()
	if !found {
		http.NotFound(writer, request)
		return
	}
	isPlaylist := strings.Contains(asset.contentType, "mpegurl")
	if rewriteOnly && !isPlaylist {
		http.NotFound(writer, request)
		return
	}
	if !rewriteOnly && isPlaylist {
		http.NotFound(writer, request)
		return
	}
	if asset.cenc != nil {
		stream.nativeServeCENC(writer, request, session, asset)
		return
	}
	if !strings.Contains(asset.contentType, "mpegurl") {
		stream.nativeWarmAhead(session, parts[0], parts[1])
	}
	ctx, cancel := context.WithCancel(providerMediaContext(request.Context(), session.credentials))
	defer cancel()
	stop := context.AfterFunc(session.ctx, cancel)
	defer stop()
	writer.Header().Set("Cache-Control", "no-store")
	if len(asset.data) > 0 && asset.total > int64(len(asset.data)) {
		if stream.nativeServePrefix(ctx, writer, request, session, asset) {
			return
		}
		asset.data = nil
	}
	if len(asset.data) > 0 {
		if strings.Contains(asset.contentType, "mpegurl") {
			body, err := stream.nativeRewrite(parts[0], session, nativeAdCleaned(session, string(asset.data), asset.address), asset.address)
			if err != nil {
				http.Error(writer, err.Error(), http.StatusBadGateway)
				return
			}
			writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			if request.Method == http.MethodGet {
				_, _ = io.WriteString(writer, body)
			}
		} else {
			writer.Header().Set("Content-Type", asset.contentType)
			if asset.etag != "" {
				writer.Header().Set("ETag", asset.etag)
			}
			http.ServeContent(writer, request, parts[1], time.Time{}, bytes.NewReader(asset.data))
		}
		return
	}
	fetchAddress := asset.address
	if session.hook != nil {
		signed, err := session.hook.SignSegment(fetchAddress)
		if err != nil {
			http.Error(writer, "播放凭证刷新失败，请重试", http.StatusBadGateway)
			return
		}
		fetchAddress = signed
	}
	upstream, err := http.NewRequestWithContext(ctx, request.Method, fetchAddress, nil)
	if err != nil {
		http.Error(writer, "媒体地址无效", http.StatusBadGateway)
		return
	}
	upstream.Header.Set("User-Agent", userAgent)
	upstream.Header.Set("Referer", session.referer)
	for _, name := range []string{"Range", "If-Range"} {
		if value := request.Header.Get(name); value != "" {
			upstream.Header.Set(name, value)
		}
	}
	response, err := stream.nativeRequest(upstream)
	if err != nil {
		if request.Method == http.MethodGet && strings.Contains(asset.contentType, "mpegurl") && stream.nativeServeRefreshedPlaylist(writer, request, session, parts[0], parts[1], asset) {
			return
		}
		http.Error(writer, "读取媒体失败，请重试", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 64<<10))
		if request.Method == http.MethodGet && strings.Contains(asset.contentType, "mpegurl") && stream.nativeServeRefreshedPlaylist(writer, request, session, parts[0], parts[1], asset) {
			return
		}
		err := stream.downloader.catalogResponseError(upstream, response, body)
		http.Error(writer, err.Error(), response.StatusCode)
		return
	}
	contentType := strings.ToLower(response.Header.Get("Content-Type"))
	finalURL := upstream.URL
	if response.Request != nil && response.Request.URL != nil {
		finalURL = response.Request.URL
	}
	playlist := strings.Contains(asset.contentType, "mpegurl") || strings.Contains(contentType, "mpegurl") || strings.HasSuffix(strings.ToLower(finalURL.Path), ".m3u8")
	if playlist && request.Method == http.MethodHead {
		writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		writer.WriteHeader(http.StatusOK)
		return
	}
	if playlist && request.Method == http.MethodGet {
		body, err := io.ReadAll(io.LimitReader(&nativeIdleTimeoutReader{reader: response.Body, idle: nativeStreamIdleTimeout}, 4<<20+1))
		if err != nil || len(body) > 4<<20 {
			http.Error(writer, "播放列表过大或读取失败", http.StatusBadGateway)
			return
		}
		text := strings.TrimSpace(strings.TrimPrefix(string(body), "\ufeff"))
		if !strings.HasPrefix(text, "#EXTM3U") {
			if stream.nativeServeRefreshedPlaylist(writer, request, session, parts[0], parts[1], asset) {
				return
			}
			http.Error(writer, "播放列表无效", http.StatusBadGateway)
			return
		}
		text = nativeAdCleaned(session, text, finalURL.String())
		rewritten, err := stream.nativeRewrite(parts[0], session, text, finalURL.String())
		if err != nil {
			http.Error(writer, err.Error(), http.StatusBadGateway)
			return
		}
		writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		_, _ = io.WriteString(writer, rewritten)
		return
	}
	if session.hook != nil && session.hook.ShortRefetch() && request.Method == http.MethodGet && request.Header.Get("Range") == "" && response.ContentLength >= 0 && response.ContentLength < nativeShortRefetchBytes {
		if stream.nativeServeShortRefetch(writer, request, session, ctx, fetchAddress, response) {
			return
		}
	}
	for _, name := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"} {
		if value := response.Header.Get(name); value != "" {
			writer.Header().Set(name, value)
		}
	}
	writer.WriteHeader(response.StatusCode)
	if request.Method == http.MethodGet {
		_, _ = io.Copy(writer, &nativeIdleTimeoutReader{reader: response.Body, idle: nativeStreamIdleTimeout})
	}
}

func (stream *nativeStreamServer) nativeServeRefreshedPlaylist(writer http.ResponseWriter, request *http.Request, session *nativeStreamSession, token, id string, asset nativeStreamAsset) bool {
	if session.hook == nil {
		return false
	}
	fresh, ok := session.hook.RefreshPlaylist(asset.address)
	if !ok || fresh == "" || fresh == asset.address {
		return false
	}
	fetchAddress := fresh
	if signed, err := session.hook.SignSegment(fetchAddress); err == nil {
		fetchAddress = signed
	} else {
		return false
	}
	ctx, cancel := context.WithCancel(providerMediaContext(request.Context(), session.credentials))
	defer cancel()
	stop := context.AfterFunc(session.ctx, cancel)
	defer stop()
	upstream, err := http.NewRequestWithContext(ctx, http.MethodGet, fetchAddress, nil)
	if err != nil {
		return false
	}
	upstream.Header.Set("User-Agent", userAgent)
	upstream.Header.Set("Referer", session.referer)
	response, err := stream.nativeRequest(upstream)
	if err != nil {
		return false
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return false
	}
	body, err := io.ReadAll(io.LimitReader(&nativeIdleTimeoutReader{reader: response.Body, idle: nativeStreamIdleTimeout}, 4<<20+1))
	if err != nil || len(body) > 4<<20 {
		return false
	}
	text := strings.TrimSpace(strings.TrimPrefix(string(body), "\ufeff"))
	if !strings.HasPrefix(text, "#EXTM3U") {
		return false
	}
	finalURL := fresh
	if response.Request != nil && response.Request.URL != nil {
		finalURL = response.Request.URL.String()
	}
	session.mu.Lock()
	if stored, found := session.assets[id]; found {
		stored.address = fresh
		session.assets[id] = stored
	}
	session.mu.Unlock()
	text = nativeAdCleaned(session, text, finalURL)
	rewritten, err := stream.nativeRewrite(token, session, text, finalURL)
	if err != nil {
		return false
	}
	writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	_, _ = io.WriteString(writer, rewritten)
	return true
}

func (stream *nativeStreamServer) nativeServeShortRefetch(writer http.ResponseWriter, request *http.Request, session *nativeStreamSession, ctx context.Context, fetchAddress string, response *http.Response) bool {
	best, _ := io.ReadAll(io.LimitReader(&nativeIdleTimeoutReader{reader: response.Body, idle: nativeStreamIdleTimeout}, nativeShortRefetchCap+1))
	bestType := response.Header.Get("Content-Type")
	status := response.StatusCode
	for attempt := 0; attempt < 3 && len(best) < nativeShortRefetchBytes; attempt++ {
		upstream, err := http.NewRequestWithContext(ctx, http.MethodGet, fetchAddress, nil)
		if err != nil {
			break
		}
		upstream.Header.Set("User-Agent", userAgent)
		upstream.Header.Set("Referer", session.referer)
		refetched, err := stream.nativeRequest(upstream)
		if err != nil {
			continue
		}
		if refetched.StatusCode != http.StatusOK && refetched.StatusCode != http.StatusPartialContent {
			refetched.Body.Close()
			continue
		}
		body, err := io.ReadAll(io.LimitReader(&nativeIdleTimeoutReader{reader: refetched.Body, idle: nativeStreamIdleTimeout}, nativeShortRefetchCap+1))
		refetched.Body.Close()
		if err != nil || int64(len(body)) > nativeShortRefetchCap {
			continue
		}
		if len(body) > len(best) {
			best = body
			bestType = refetched.Header.Get("Content-Type")
			status = refetched.StatusCode
		}
	}
	if bestType != "" {
		writer.Header().Set("Content-Type", bestType)
	}
	writer.Header().Set("Content-Length", strconv.Itoa(len(best)))
	writer.WriteHeader(status)
	_, _ = writer.Write(best)
	return true
}
