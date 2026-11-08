package seku

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// ---- local library store (v4) ----
//
// The Dart UI browses sources through two reads (core_bridge.dart /
// catalog_browser.dart, blutter asm):
//   cached  {action, source, category}          -> core-local library page
//   catalog {action, source, category, page, force, query} -> live page
// and maintains per-source state through sourceJob/sourceStatus, whose
// payload is a SourceStatus object (source_status.dart fromJson):
//   {source, count, unknownVip, page, hasMore, updatedAt, running,
//    operation, stage, completed, total, added, error, storageError,
//    startedAt, finishedAt, retryAt,
//    health: {checkedAt, state, sample, steps:[{name, state, message,
//             host, httpStatus, elapsedMs, cfRay}]}}
//
// Dual mode (user requirement, 2026-10-23): queries are LIVE — catalog
// always fetches the requested page from the origin site, and cached on
// an empty store fetches page 1 live instead of returning an empty page.
// Everything fetched is merged into this store. The sources screen's
// "更新" (sourceJob) additionally persists pages up front and maintains
// count/updatedAt so the stored library is browsable/searchable offline.
// Both modes share the same provider fetch layer; there is one parser.

type catStore struct {
	Pages   map[int][]map[string]interface{} `json:"pages"`
	MaxPage int                              `json:"maxPage"`
	HasMore bool                             `json:"hasMore"`
}

type slotStore struct {
	Slot       string                 `json:"slot"`
	Cats       map[string]*catStore   `json:"cats"`
	Count      int                    `json:"count"`
	UpdatedAt  int64                  `json:"updatedAt"` // ms epoch
	StartedAt  int64                  `json:"startedAt"`
	FinishedAt int64                  `json:"finishedAt"`
	Operation  string                 `json:"operation"`
	Stage      string                 `json:"stage"`
	Completed  int                    `json:"completed"`
	Total      int                    `json:"total"`
	Added      int                    `json:"added"`
	Error      string                 `json:"error"`
	Health     map[string]interface{} `json:"health,omitempty"`

	// runtime only
	running bool
	cancel  bool
	loaded  bool
}

var (
	storeMu  sync.Mutex
	storeDir string
	stores   = map[string]*slotStore{}
)

func nowMs() int64 { return time.Now().UnixMilli() }

// isoMs renders a ms-epoch timestamp as an ISO-8601 string. Dart's
// sourceTime (_interpolateSingle -> DateTime.tryParse) only parses
// strings; a numeric ms value stringifies to digits and parses to null,
// which the UI shows as 「尚无记录」 (trace_A.md §3.2).
func isoMs(ms int64) interface{} {
	if ms <= 0 {
		return nil
	}
	return time.UnixMilli(ms).UTC().Format("2006-01-02T15:04:05.000Z")
}

func setStoreDir(dir string) {
	if dir == "" {
		return
	}
	storeMu.Lock()
	defer storeMu.Unlock()
	if storeDir == "" {
		storeDir = dir
	}
}

// storeBaseDirLocked: caller must hold storeMu (or be in a context where
// storeDir is stable). Go mutexes are NOT reentrant: getStore/saveStore
// run with storeMu held, so any nested locking call self-deadlocks — the
// first version did exactly that and hung the first sourceStatus call.
func storeBaseDirLocked() string {
	if storeDir != "" {
		return filepath.Join(storeDir, "pilot_store")
	}
	return filepath.Join(os.TempDir(), "duanju_pilot_store")
}

func storeBaseDir() string {
	storeMu.Lock()
	defer storeMu.Unlock()
	return storeBaseDirLocked()
}

func slotFile(slot string) string {
	return filepath.Join(storeBaseDirLocked(), slot+".json")
}

// getStore loads (once) and returns the slot store. Caller holds no lock;
// the returned pointer is guarded by storeMu in all helpers below.
func getStore(slot string) *slotStore {
	storeMu.Lock()
	defer storeMu.Unlock()
	if st, ok := stores[slot]; ok && st.loaded {
		return st
	}
	st := &slotStore{Slot: slot, Cats: map[string]*catStore{}, loaded: true}
	if b, err := os.ReadFile(slotFile(slot)); err == nil {
		_ = json.Unmarshal(b, st)
		st.Slot = slot
		st.loaded = true
		st.running = false
		st.cancel = false
		if st.Cats == nil {
			st.Cats = map[string]*catStore{}
		}
	}
	stores[slot] = st
	return st
}

// saveStore persists; caller must hold storeMu.
func saveStore(st *slotStore) {
	if st == nil {
		return
	}
	dir := storeBaseDirLocked()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}
	b, err := json.Marshal(st)
	if err != nil {
		return
	}
	tmp := slotFile(st.Slot) + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err == nil {
		_ = os.Rename(tmp, slotFile(st.Slot))
	}
}

func catKey(slot, category string) string {
	if category == "" {
		return defaultCategory(slot)
	}
	return category
}

func (st *slotStore) cat(category string) *catStore {
	key := catKey(st.Slot, category)
	cs, ok := st.Cats[key]
	if !ok {
		cs = &catStore{Pages: map[int][]map[string]interface{}{}, HasMore: true}
		st.Cats[key] = cs
	}
	return cs
}

// mergePage merges one fetched page into the store; returns how many items
// were new (by drama id) across the whole slot store.
func (st *slotStore) mergePage(category string, page int, items []interface{}, hasMore bool) int {
	cs := st.cat(category)
	pageItems := []map[string]interface{}{}
	for _, it := range items {
		if m, ok := it.(map[string]interface{}); ok {
			pageItems = append(pageItems, m)
		}
	}
	before := st.uniqueIDs()
	cs.Pages[page] = pageItems
	if page > cs.MaxPage {
		cs.MaxPage = page
	}
	cs.HasMore = hasMore
	after := st.uniqueIDs()
	st.Count = len(after)
	return len(after) - len(before)
}

func (st *slotStore) uniqueIDs() map[string]bool {
	ids := map[string]bool{}
	for _, cs := range st.Cats {
		for _, pageItems := range cs.Pages {
			for _, d := range pageItems {
				if id, _ := d["id"].(string); id != "" {
					ids[id] = true
				}
			}
		}
	}
	return ids
}

// storedItems flattens stored pages of one category in page order.
func (st *slotStore) storedItems(category string) ([]interface{}, int, bool) {
	cs := st.cat(category)
	out := []interface{}{}
	seen := map[string]bool{}
	for p := 1; p <= cs.MaxPage; p++ {
		for _, d := range cs.Pages[p] {
			id, _ := d["id"].(string)
			if id != "" && seen[id] {
				continue
			}
			if id != "" {
				seen[id] = true
			}
			out = append(out, d)
		}
	}
	return out, cs.MaxPage, cs.HasMore
}

func (st *slotStore) findDrama(rawID string) map[string]interface{} {
	for _, cs := range st.Cats {
		for _, pageItems := range cs.Pages {
			for _, d := range pageItems {
				if v, _ := d["sourceId"].(string); v == rawID {
					return d
				}
				if v, _ := d["id"].(string); v == rawID || v == st.Slot+":"+rawID {
					return d
				}
			}
		}
	}
	return nil
}

// statusMap renders the SourceStatus payload for this slot.
func (st *slotStore) statusMap() map[string]interface{} {
	def := st.cat(defaultCategory(st.Slot))
	m := map[string]interface{}{
		"source":       st.Slot,
		"count":        st.Count,
		"unknownVip":   0,
		"page":         def.MaxPage,
		"hasMore":      def.HasMore,
		"updatedAt":    isoMs(st.UpdatedAt),
		"running":      st.running,
		"operation":    st.Operation,
		"stage":        st.Stage,
		"completed":    st.Completed,
		"total":        st.Total,
		"added":        st.Added,
		"error":        st.Error,
		"storageError": "",
		"startedAt":    isoMs(st.StartedAt),
		"finishedAt":   isoMs(st.FinishedAt),
		"retryAt":      nil,
	}
	if st.Health != nil {
		m["health"] = st.Health
	}
	return m
}

func statusForSlot(slot string) map[string]interface{} {
	st := getStore(slot)
	storeMu.Lock()
	defer storeMu.Unlock()
	return st.statusMap()
}

// statusForOtherSource renders a benign SourceStatus for one of the 21
// original sources the pilot core does not implement (v4) — the UI must
// render its card (0 部 / no health) without ever erroring out.
func statusForOtherSource(id string) map[string]interface{} {
	return map[string]interface{}{
		"source": id, "count": 0, "unknownVip": 0, "page": 0,
		"hasMore": false, "updatedAt": nil, "running": false,
		"operation": "", "stage": "", "completed": 0, "total": 0,
		"added": 0, "error": "", "storageError": "",
		"startedAt": nil, "finishedAt": nil, "retryAt": nil,
	}
}

// ---- source jobs ----

var jobMu sync.Mutex

// runSourceJob handles action=sourceJob / cancelSourceJob for a pilot
// slot and returns the SourceStatus payload to answer with.
func runSourceJob(slot, command string, drama map[string]interface{}) map[string]interface{} {
	st := getStore(slot)
	switch command {
	case "cancel":
		storeMu.Lock()
		st.cancel = true
		st.running = false
		st.Stage = "cancelled"
		st.FinishedAt = nowMs()
		saveStore(st)
		m := st.statusMap()
		storeMu.Unlock()
		return m
	case "check", "checkCatalog":
		return checkSource(slot, command == "check")
	case "retrySave":
		storeMu.Lock()
		saveStore(st)
		m := st.statusMap()
		storeMu.Unlock()
		return m
	case "update", "more", "metadata", "vipMetadata":
		// fallthrough to job start below
	default:
		// Unknown command: report current status, never error.
		return statusForSlot(slot)
	}

	jobMu.Lock()
	storeMu.Lock()
	if st.running {
		m := st.statusMap()
		storeMu.Unlock()
		jobMu.Unlock()
		return m
	}
	st.running = true
	st.cancel = false
	st.Operation = command
	st.Stage = "submitted"
	st.StartedAt = nowMs()
	st.FinishedAt = 0
	st.Error = ""
	st.Added = 0
	st.Completed = 0
	st.Total = 0
	storeMu.Unlock()
	jobMu.Unlock()

	if command == "metadata" || command == "vipMetadata" {
		go jobMetadata(st, drama)
	} else if command == "more" {
		go jobMore(st)
	} else {
		go jobUpdate(st)
	}
	return statusForSlot(slot)
}

func jobFinish(st *slotStore, stage string, added int, err error) {
	storeMu.Lock()
	defer storeMu.Unlock()
	st.running = false
	st.Added = added
	st.Stage = stage
	st.FinishedAt = nowMs()
	if err != nil {
		st.Error = "更新失败，请稍后重试"
	} else {
		st.Error = ""
		st.UpdatedAt = st.FinishedAt
	}
	saveStore(st)
}

// jobUpdate implements 「更新会查找新剧、继续加载一页历史内容、并分批补齐
// 资料」 for our sources: page 1 of every category (new items), plus one
// further page of the default category (history), all merged live.
func jobUpdate(st *slotStore) {
	slot := st.Slot
	cats := providerCategoryIDs(slot)
	if len(cats) == 0 {
		cats = []string{defaultCategory(slot)}
	}
	storeMu.Lock()
	st.Total = len(cats) + 1
	st.Stage = "catalog"
	storeMu.Unlock()

	added := 0
	var lastErr error
	done := 0
	for _, cat := range cats {
		if isCancelled(st) {
			jobFinish(st, "cancelled", added, nil)
			return
		}
		items, _, hasMore, err := providerCatalog(slot, cat, 1)
		if err != nil {
			lastErr = err
		} else {
			storeMu.Lock()
			added += st.mergePage(cat, 1, items, hasMore)
			st.Completed = done + 1
			saveStore(st)
			storeMu.Unlock()
		}
		done++
	}
	// one more (history) page of the default category
	if !isCancelled(st) {
		def := defaultCategory(slot)
		storeMu.Lock()
		nextPage := st.cat(def).MaxPage + 1
		storeMu.Unlock()
		items, _, hasMore, err := providerCatalog(slot, def, nextPage)
		if err == nil {
			storeMu.Lock()
			added += st.mergePage(def, nextPage, items, hasMore)
			storeMu.Unlock()
		}
	}
	storeMu.Lock()
	st.Completed = st.Total
	storeMu.Unlock()
	jobFinish(st, "completed", added, lastErr)
}

func jobMore(st *slotStore) {
	slot := st.Slot
	def := defaultCategory(slot)
	storeMu.Lock()
	st.Total = 1
	st.Stage = "catalog"
	nextPage := st.cat(def).MaxPage + 1
	storeMu.Unlock()
	items, _, hasMore, err := providerCatalog(slot, def, nextPage)
	added := 0
	if err == nil {
		storeMu.Lock()
		added = st.mergePage(def, nextPage, items, hasMore)
		st.Completed = 1
		storeMu.Unlock()
	}
	jobFinish(st, "completed", added, err)
}

// jobMetadata enriches stored dramas with detail data (cover/desc),
// optionally just the one drama passed with the job.
func jobMetadata(st *slotStore, only map[string]interface{}) {
	slot := st.Slot
	targets := []string{}
	if only != nil {
		if v, _ := only["vod_id"].(string); v != "" {
			targets = append(targets, v)
		} else if id, _ := only["id"].(string); id != "" {
			_, raw := splitDramaID(slot, id)
			targets = append(targets, raw)
		}
	}
	if len(targets) == 0 {
		storeMu.Lock()
		for rawID := range st.uniqueRawIDs() {
			targets = append(targets, rawID)
		}
		storeMu.Unlock()
	}
	if len(targets) > 60 {
		targets = targets[:60]
	}
	storeMu.Lock()
	st.Total = len(targets)
	st.Stage = "metadata"
	storeMu.Unlock()
	done := 0
	for _, raw := range targets {
		if isCancelled(st) {
			jobFinish(st, "cancelled", 0, nil)
			return
		}
		if d, err := providerDetail(slot, raw); err == nil && d != nil {
			storeMu.Lock()
			st.replaceDrama(raw, d)
			storeMu.Unlock()
		}
		done++
		storeMu.Lock()
		st.Completed = done
		storeMu.Unlock()
	}
	jobFinish(st, "completed", 0, nil)
}

func (st *slotStore) uniqueRawIDs() map[string]bool {
	ids := map[string]bool{}
	for _, cs := range st.Cats {
		for _, pageItems := range cs.Pages {
			for _, d := range pageItems {
				if v, _ := d["vod_id"].(string); v != "" {
					ids[v] = true
				}
			}
		}
	}
	return ids
}

func (st *slotStore) replaceDrama(rawID string, fresh map[string]interface{}) {
	for _, cs := range st.Cats {
		for p, pageItems := range cs.Pages {
			for i, d := range pageItems {
				if v, _ := d["vod_id"].(string); v == rawID {
					cs.Pages[p][i] = fresh
				}
			}
		}
	}
	saveStore(st)
}

func isCancelled(st *slotStore) bool {
	storeMu.Lock()
	defer storeMu.Unlock()
	return st.cancel
}

// ---- health check （检测连接与播放） ----

// checkSource runs a real check for a pilot slot and returns the
// SourceStatus payload with a health block attached. With playback=true
// (command "check") the first stored/fetched drama is also resolved.
func checkSource(slot string, playback bool) map[string]interface{} {
	st := getStore(slot)
	home := providerHomeURL(slot)
	host := ""
	if u, err := url.Parse(home); err == nil {
		host = u.Host
	}
	steps := []interface{}{}
	healthState := "ok"
	sample := ""

	step := func(name string, ok bool, msg string, status int, ms int64) {
		state := "ok"
		if !ok {
			state = "failed"
			healthState = "failed"
		}
		steps = append(steps, map[string]interface{}{
			"name": name, "state": state, "message": msg, "host": host,
			"httpStatus": status, "elapsedMs": ms, "cfRay": "",
		})
	}

	// 1) connection
	t0 := time.Now()
	_, code, _, err := httpGet(home, providerHeaders(slot))
	step("站点连接", err == nil && code == 200, httpMsg(code, err), code, time.Since(t0).Milliseconds())

	// 2) catalog
	t0 = time.Now()
	items, _, hm, cerr := providerCatalog(slot, defaultCategory(slot), 1)
	code2 := 200
	if cerr != nil {
		code2 = 0
	}
	step("目录抓取", cerr == nil && len(items) > 0, fmt.Sprintf("取得 %d 条", len(items)), code2, time.Since(t0).Milliseconds())
	if len(items) > 0 {
		if m, ok := items[0].(map[string]interface{}); ok {
			sample, _ = m["title"].(string)
			// a working check also seeds the store (harmless, useful)
			storeMu.Lock()
			st.mergePage(defaultCategory(slot), 1, items, hm)
			saveStore(st)
			storeMu.Unlock()
		}
	}

	// 3) playback (only for full check)
	if playback {
		t0 = time.Now()
		okPlay := false
		msg := "无可检测剧集"
		if len(items) > 0 {
			if m, ok := items[0].(map[string]interface{}); ok {
				raw, _ := m["vod_id"].(string)
				if res, rerr := providerResolve(slot, raw); rerr == nil && res != nil {
					if u, _ := res["url"].(string); strings.HasPrefix(u, "http") {
						okPlay = true
						msg = "已解析到播放地址"
					}
				}
				if !okPlay {
					msg = "播放解析失败"
				}
			}
		}
		step("播放解析", okPlay, msg, 200, time.Since(t0).Milliseconds())
	}

	health := map[string]interface{}{
		"checkedAt": isoMs(nowMs()),
		"state":     healthState,
		"sample":    sample,
		"steps":     steps,
	}
	storeMu.Lock()
	st.Health = health
	saveStore(st)
	m := st.statusMap()
	storeMu.Unlock()
	return m
}

func httpMsg(code int, err error) string {
	if err != nil {
		return "连接失败"
	}
	return fmt.Sprintf("HTTP %d", code)
}
