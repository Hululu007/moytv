package core

import (
	"context"
	"errors"
	"fmt"
	"html"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"

	"moyi/native/core/seku"
)

type nativeCategory struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

var nativeAICategories = []nativeCategory{
	{ID: "ai-duanju", Name: "AI 短剧"},
	{ID: "ai-manju", Name: "AI 漫剧"},
	{ID: "ai-huanlian", Name: "AI 换脸"},
	{ID: "ai-mogai", Name: "AI 魔改"},
}

func nativeCatalogKey(source, category string) string {
	source = canonicalProviderSource(source)
	if category = strings.TrimSpace(category); category != "" {
		return source + "|" + strings.ReplaceAll(category, "|", "\x1f")
	}
	return source
}

func validNativeCategory(source, category string) bool {
	if category == "" {
		return true
	}
	if isSekuSource(source) {
		if len(category) > 128 || strings.ContainsAny(category, "\\\x00\r\n") {
			return false
		}
		return true
	}
	if len(category) > 128 || strings.ContainsAny(category, "|\\\x00\r\n") {
		return false
	}
	if isCustomMaccmsSource(source) {
		// 自定义 MacCMS 源的分类 ID 允许是路径形式（/fenlei/1、/listnews/2 等），
		// 上面已排除缓存键分隔符 |、反斜杠与控制字符，这里直接放行。
		return true
	}
	switch source {
	case sourceHGTV:
		if _, ok := hgtvCategoryFor(category); ok {
			return true
		}
	case sourceHGTVMirror:
		return hgtvMirrorCategoryID.MatchString(category)
	case sourceHongguo:
		for _, genre := range hongguoAppGenres {
			if category == genre.key {
				return true
			}
		}
		return hongguoIsBookCategory(category)
	case sourceHuangguoAI:
		for _, entry := range nativeAICategories {
			if category == entry.ID {
				return true
			}
		}
	case sourceHuangguoVideo:
		id, err := strconv.Atoi(category)
		return err == nil && id > 0
	case sourceCloudFront:
		return strings.TrimSpace(category) == category
	case sourceHuangju:
		return category == huangjuNewestCategory || validHuangjuID(category) && !strings.HasPrefix(category, "@")
	case sourceYeguo:
		return validYeguoCategory(category)
	case sourceDSD:
		return webProviderNumericID.MatchString(category)
	case sourceGuipian:
		return validGuipianCategory(category)
	case sourceHanxiaoquan:
		return validHanxiaoquanCategory(category)
	case sourceIkanbot:
		return validIkanbotCategory(category)
	case sourceA123:
		return validA123Category(category)
	}
	if isDuanjuProviderSource(source) {
		return validDuanjuCategory(source, category)
	}
	return false
}

func (engine *nativeEngine) nativeCategories(ctx context.Context, source string, force bool) ([]nativeCategory, error) {
	source = canonicalProviderSource(source)
	all := []nativeCategory{{Name: "全部"}}
	switch source {
	case sourceHGTV:
		for _, entry := range hgtvCategories {
			all = append(all, nativeCategory{ID: entry.id, Name: entry.name})
		}
		return all, nil
	case sourceHGTVMirror:
		return append(all, engine.downloader.fetchHGTVMirrorCategories(ctx)...), nil
	case sourceHongguo:
		for _, genre := range hongguoAppGenres {
			all = append(all, nativeCategory{ID: genre.key, Name: genre.name})
		}
		all = append(all, nativeCategory{ID: "novel", Name: "小说"}, nativeCategory{ID: "audio", Name: "听书"})
		return all, nil
	case sourceHuangguoAI:
		return append(all, nativeAICategories...), nil
	case sourceHuangdou:
		return all, nil
	}
	if slot, ok := sekuSlotForSource(source); ok {
		seku.Init(engine.directory)
		merged := append([]nativeCategory{}, all...)
		for _, category := range seku.Categories(slot) {
			merged = append(merged, nativeCategory{ID: category.ID, Name: category.Name})
		}
		engine.mu.Lock()
		if engine.categoryOptions == nil {
			engine.categoryOptions = map[string][]nativeCategory{}
		}
		engine.categoryOptions[source] = merged
		engine.mu.Unlock()
		return merged, nil
	}
	if isCustomMaccmsSource(source) {
		// 自定义 maccms 站点：从首页导航实时提取分类；识别不到则仅展示"全部"。
		categories, err := engine.downloader.fetchMaccmsCustomCategories(ctx, source)
		if err != nil || len(categories) == 0 {
			return all, nil
		}
		merged := append(all, categories...)
		engine.mu.Lock()
		if engine.categoryOptions == nil {
			engine.categoryOptions = map[string][]nativeCategory{}
		}
		engine.categoryOptions[source] = merged
		engine.mu.Unlock()
		return merged, nil
	}
	// 实时抓取口径：分类一律现抓，不再因本地已有分类表而跳过站源请求；
	// categoryOptions 只作回写（供持久化与离线兜底数据），不作请求短路。
	d := engine.downloader
	var err error
	switch source {
	case sourceCloudFront:
		var tabs legacyTabList
		err = d.fetchAPI(ctx, "/api/app/playlet-tab/all", nil, &tabs)
		for _, tab := range tabs {
			if validNativeCategory(source, tab.ID) && tab.ID != "" && tab.Name != "" {
				all = append(all, nativeCategory{ID: tab.ID, Name: tab.Name})
			}
		}
	case sourceHuangguoVideo:
		address := d.providerBaseURL(source) + "/videos"
		var body string
		body, err = d.fetchProviderText(ctx, address, d.providerBaseURL(source)+"/")
		if err == nil {
			all = append(all, parseHuangguoVideoCategories(body)...)
		}
	case sourceHuangju:
		var categories []nativeCategory
		categories, err = d.fetchHuangjuCategories(ctx)
		if err == nil {
			all = append(all, categories...)
		}
	case sourceYeguo:
		var categories []nativeCategory
		categories, err = d.fetchYeguoCategories(ctx)
		if err == nil {
			all = append(all, categories...)
		}
	case sourceDSD:
		var categories []nativeCategory
		categories, err = d.fetchDSDCategories(ctx, force)
		if err == nil {
			all = append(all, categories...)
		}
	case sourceGuipian:
		all = append(all, d.fetchGuipianCategories()...)
	case sourceHanxiaoquan:
		all = append(all, d.fetchHanxiaoquanCategories()...)
	case sourceIkanbot:
		all = append(all, d.fetchIkanbotCategories()...)
	case sourceA123:
		all = append(all, d.fetchA123Categories()...)
	default:
		if isDuanjuProviderSource(source) {
			var categories []nativeCategory
			categories, err = d.fetchDuanjuCategories(ctx, source)
			if err == nil {
				all = append(all, categories...)
			}
			break
		}
		return nil, errors.New("请选择有效站源")
	}
	if err != nil {
		return nil, err
	}
	if len(all) == 1 {
		return nil, errors.New("站源暂未返回内容分类，请稍后重试")
	}
	engine.mu.Lock()
	if engine.categoryOptions == nil {
		engine.categoryOptions = map[string][]nativeCategory{}
	}
	engine.categoryOptions[source] = all
	engine.writeCatalogDiskLocked()
	engine.mu.Unlock()
	return all, nil
}

var categoryAnchorPattern = regexp.MustCompile(`(?is)<a\b([^>]*)>(.*?)</a>`)
var categoryTextPattern = regexp.MustCompile(`(?s)<[^>]*>`)

func parseHuangguoVideoCategories(body string) []nativeCategory {
	var categories []nativeCategory
	seen := map[string]bool{}
	for _, match := range categoryAnchorPattern.FindAllStringSubmatch(body, -1) {
		href := html.UnescapeString(extractAttr("<a "+match[1]+">", "href"))
		address, err := url.Parse(href)
		if err != nil || address.Path != "" && strings.TrimRight(address.Path, "/") != "/videos" {
			continue
		}
		id := address.Query().Get("category")
		name := strings.TrimSpace(html.UnescapeString(categoryTextPattern.ReplaceAllString(match[2], "")))
		if !validNativeCategory(sourceHuangguoVideo, id) || id == "" || seen[id] || name == "" || len([]rune(name)) > 24 {
			continue
		}
		seen[id] = true
		categories = append(categories, nativeCategory{ID: id, Name: name})
	}
	return categories
}

func (d *Downloader) fetchHuangguoAICatalogPage(ctx context.Context, page int, category string) ([]Drama, bool, error) {
	categories := nativeAICategories
	if category != "" {
		for _, entry := range categories {
			if entry.ID == category {
				categories = []nativeCategory{entry}
				break
			}
		}
	}
	type categoryResult struct {
		items []Drama
		err   error
	}
	results := make([]categoryResult, len(categories))
	slots := make(chan struct{}, 2)
	var group sync.WaitGroup
	for index, entry := range categories {
		group.Add(1)
		go func(index int, entry nativeCategory) {
			defer group.Done()
			select {
			case slots <- struct{}{}:
				defer func() { <-slots }()
			case <-ctx.Done():
				results[index].err = ctx.Err()
				return
			}
			address := fmt.Sprintf("%s/api/videos/category/%s?sort=hot&page=%d&size=24", d.providerBaseURL(sourceHuangguoAI), url.PathEscape(entry.ID), page)
			body, err := d.fetchProviderText(ctx, address, d.providerBaseURL(sourceHuangguoAI)+"/"+entry.ID+"/")
			if err == nil {
				results[index].items = parseHuangguoAIJSONCards([]byte(body), address, entry.Name)
			}
			if err != nil {
				results[index].err = fmt.Errorf("%s: %w", entry.Name, err)
			}
		}(index, entry)
	}
	group.Wait()
	var items []Drama
	var failures []error
	more := false
	for _, result := range results {
		items = append(items, result.items...)
		more = more || len(result.items) >= 24 || result.err != nil
		if result.err != nil {
			failures = append(failures, result.err)
		}
	}
	return items, more, errors.Join(failures...)
}
