package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

var hongguoBookCategories = []struct {
	id   string
	name string
}{
	{"1", "都市"},
	{"2", "都市生活"},
	{"3", "现代言情"},
	{"4", "校园"},
	{"5", "古代言情"},
	{"6", "奇幻"},
	{"7", "玄幻"},
	{"8", "科幻末世"},
	{"9", "仙侠"},
	{"10", "悬疑"},
	{"11", "乡村"},
	{"12", "历史"},
	{"13", "军事"},
	{"15", "体育"},
}

func hongguoBookCategoryName(id string) string {
	for _, entry := range hongguoBookCategories {
		if entry.id == id {
			return entry.name
		}
	}
	return ""
}

func hongguoIsBookCategory(category string) bool {
	if category == "novel" || category == "audio" {
		return true
	}
	if strings.HasPrefix(category, "bcat") {
		return hongguoBookCategoryName(strings.TrimPrefix(category, "bcat")) != ""
	}
	return false
}

func hongguoBookFromAny(row map[string]any, kind, categoryName string) Drama {
	bookID := mapString(row, "book_id", "bookid")
	if !hongguoNumericID.MatchString(bookID) {
		return Drama{}
	}
	title := firstNonEmpty(mapString(row, "book_name", "book_short_name"), bookID)
	cover := firstNonEmpty(mapString(row, "thumb_url", "detail_page_thumb_url"))
	intro := firstNonEmpty(mapString(row, "abstract", "book_abstract_v2"))
	serial := mapString(row, "serial_count", "content_chapter_number")
	remark := ""
	if serial != "" {
		remark = "共" + serial + "章"
	}
	sourceID := kind + ":" + bookID
	drama := Drama{
		Title: title, Name: title, Desc: intro, Intro: intro,
		Cover: cover, CoverURL: cover, CategoryName: categoryName,
		Remark: remark, TotalEpisode: serial, EpisodeCount: serial,
	}
	drama.ID = providerDramaID(sourceHongguo, sourceID)
	drama.Source = sourceHongguo
	drama.SourceID = sourceID
	return drama
}

func hongguoBookmallTabTitle(tabType int) string {
	if tabType == 2 {
		return "小说"
	}
	return "听书"
}

func hongguoCollectBookmallCells(node any, cellFilter string, kind, categoryName string, seen map[string]bool, out *[]Drama, categories *[]nativeFilterOption) {
	m, ok := node.(map[string]any)
	if !ok {
		return
	}
	if books, ok := m["book_data"].([]any); ok && len(books) > 0 {
		for _, bookNode := range books {
			if bookMap, ok := bookNode.(map[string]any); ok {
				bookCategory := mapString(bookMap, "category")
				if bookCategory != "" && categories != nil {
					found := false
					for _, option := range *categories {
						if option.ID == bookCategory {
							found = true
							break
						}
					}
					if !found {
						*categories = append(*categories, nativeFilterOption{ID: bookCategory, Name: bookCategory})
					}
				}
				if cellFilter == "" || cellFilter == bookCategory {
					if drama := hongguoBookFromAny(bookMap, kind, categoryName); drama.ID != "" && !seen[drama.SourceID] {
						seen[drama.SourceID] = true
						*out = append(*out, drama)
					}
				}
			}
		}
	}
	if subCells, ok := m["cell_data"].([]any); ok {
		for _, sub := range subCells {
			hongguoCollectBookmallCells(sub, cellFilter, kind, categoryName, seen, out, categories)
		}
	}
}

func hongguoNovelFilterGroups() []nativeFilterGroup {
	options := []nativeFilterOption{{ID: "", Name: "全部"}}
	for _, entry := range hongguoBookCategories {
		options = append(options, nativeFilterOption{ID: entry.id, Name: entry.name})
	}
	return []nativeFilterGroup{
		{Key: "ncat", Name: "二级分类", Options: options},
		{Key: "nstatus", Name: "状态", Options: []nativeFilterOption{
			{ID: "", Name: "全部"}, {ID: "0", Name: "完结"}, {ID: "1", Name: "连载中"}, {ID: "3", Name: "今日更新"},
		}},
		{Key: "nsort", Name: "排序", Options: []nativeFilterOption{
			{ID: "", Name: "综合"}, {ID: "24", Name: "热门"}, {ID: "76", Name: "最新"}, {ID: "12", Name: "评分"},
		}},
	}
}

func (d *Downloader) fetchHongguoBookmallCatalog(ctx context.Context, tabType int, cellFilter string, scans int) ([]Drama, []nativeFilterGroup, error) {
	kind := "audio"
	if tabType == 2 {
		kind = "novel"
	}
	categoryName := hongguoBookmallTabTitle(tabType)
	if scans < 1 {
		scans = 1
	}
	seen := map[string]bool{}
	items := []Drama{}
	var categories []nativeFilterOption
	for scan := 0; scan < scans; scan++ {
		result, err := d.hongguoAppRequest(ctx, http.MethodGet, "/reading/bookapi/bookmall/tab/v", url.Values{"tab_type": {strconv.Itoa(tabType)}}, nil)
		if err != nil {
			if len(items) > 0 {
				break
			}
			return nil, nil, err
		}
		for _, tabNode := range anyList(nestedMap(result, "data")["tab_item"]) {
			tabMap, ok := tabNode.(map[string]any)
			if !ok {
				continue
			}
			tabValue, _ := strconv.Atoi(mapString(tabMap, "tab_type"))
			if tabValue != tabType {
				continue
			}
			hongguoCollectBookmallCells(tabMap, cellFilter, kind, categoryName, seen, &items, &categories)
		}
	}
	if len(items) == 0 {
		return nil, nil, errors.New("红果书城未返回书目")
	}
	options := []nativeFilterOption{{ID: "", Name: "全部"}}
	options = append(options, categories...)
	filters := []nativeFilterGroup{{Key: "category", Name: "分类", Options: options}}
	return items, filters, nil
}

func (d *Downloader) fetchHongguoBookCategoryCatalog(ctx context.Context, catID, sub, status, sort string, page int) ([]Drama, []nativeFilterGroup, bool, error) {
	query := url.Values{"category_id": {catID}, "offset": {strconv.Itoa((page - 1) * 10)}}
	if sub != "" {
		query.Set("sub_category_id", sub)
	}
	if status != "" {
		query.Set("book_status", status)
	}
	if sort != "" {
		query.Set("sort_by", sort)
	}
	result, err := d.hongguoAppRequest(ctx, http.MethodGet, "/reading/bookapi/new_category/landing/v", query, nil)
	if err != nil {
		return nil, nil, false, err
	}
	data := nestedMap(result, "data")
	rule := nestedMap(data, "rule")
	subOptions := []nativeFilterOption{{ID: "", Name: "全部"}}
	for _, subNode := range anyList(rule["sub_category"]) {
		if subMap, ok := subNode.(map[string]any); ok {
			name := mapString(subMap, "name")
			if name == "" || name == "全部" {
				continue
			}
			subOptions = append(subOptions, nativeFilterOption{ID: mapString(subMap, "value"), Name: name})
		}
	}
	filters := []nativeFilterGroup{
		{Key: "sub", Name: "二级分类", Options: subOptions},
		{Key: "status", Name: "状态", Options: []nativeFilterOption{
			{ID: "", Name: "全部"}, {ID: "0", Name: "完结"}, {ID: "1", Name: "连载中"}, {ID: "3", Name: "今日更新"},
		}},
		{Key: "sort", Name: "排序", Options: []nativeFilterOption{
			{ID: "", Name: "综合"}, {ID: "24", Name: "热门"}, {ID: "76", Name: "最新"}, {ID: "12", Name: "评分"},
		}},
	}
	seen := map[string]bool{}
	items := []Drama{}
	categoryName := hongguoBookCategoryName(catID)
	for _, bookNode := range anyList(data["book_info"]) {
		if bookMap, ok := bookNode.(map[string]any); ok {
			if drama := hongguoBookFromAny(bookMap, "novel", categoryName); drama.ID != "" && !seen[drama.SourceID] {
				seen[drama.SourceID] = true
				items = append(items, drama)
			}
		}
	}
	hasMore := false
	if v, ok := data["has_more"].(bool); ok {
		hasMore = v
	}
	return items, filters, hasMore, nil
}

func hongguoDecodeFontText(text string) string {
	var out []rune
	for _, r := range text {
		if mapped, ok := hongguoFontMap[r]; ok {
			out = append(out, mapped)
		} else {
			out = append(out, r)
		}
	}
	return string(out)
}

var hongguoReaderParagraphPattern = regexp.MustCompile(`(?s)<p[^>]*>(.*?)</p>`)
var hongguoTagPattern = regexp.MustCompile(`<[^>]+>`)

func hongguoReaderChapterText(ctx context.Context, d *Downloader, itemID string) (string, error) {
	ctx = context.WithValue(ctx, providerTextUserAgentKey{}, "Mozilla/5.0")
	body, err := d.fetchProviderText(ctx, "https://fanqienovel.com/reader/"+url.PathEscape(itemID), "https://fanqienovel.com/")
	if err != nil {
		return "", err
	}
	var paras []string
	for _, match := range hongguoReaderParagraphPattern.FindAllStringSubmatch(body, -1) {
		text := strings.TrimSpace(html.UnescapeString(hongguoTagPattern.ReplaceAllString(match[1], "")))
		if text == "" {
			continue
		}
		privateCount := 0
		for _, r := range text {
			if r >= 0xE000 && r <= 0xF8FF {
				privateCount++
			}
		}
		if privateCount >= 3 {
			text = hongguoDecodeFontText(text)
		}
		paras = append(paras, text)
	}
	if len(paras) == 0 {
		return "", errors.New("小说章节正文为空")
	}
	return strings.Join(paras, "\n"), nil
}

func (d *Downloader) fetchHongguoNovelDetail(ctx context.Context, bookID string) (Drama, []Chapter, error) {
	result, err := d.hongguoAppRequest(ctx, http.MethodGet, "/reading/bookapi/multi-detail/v", url.Values{"book_id": {bookID}, "book_type": {"1"}}, nil)
	if err != nil {
		return Drama{}, nil, err
	}
	rows := anyList(result["data"])
	var book map[string]any
	if len(rows) > 0 {
		book, _ = rows[0].(map[string]any)
	}
	if book == nil {
		if m, ok := result["data"].(map[string]any); ok {
			book = m
		}
	}
	if book == nil {
		book = map[string]any{}
	}
	drama := hongguoBookFromAny(book, "novel", "小说")
	if drama.ID == "" {
		drama = Drama{
			Title: mapString(book, "book_short_name", "original_book_name", "book_flight_alias_name"),
			Name:  mapString(book, "book_short_name", "original_book_name", "book_flight_alias_name"),
			Desc:  mapString(book, "abstract", "book_abstract_v2"),
			Intro: mapString(book, "abstract", "book_abstract_v2"),
			Cover: mapString(book, "thumb_url", "detail_page_thumb_url"),
		}
		drama.CoverURL = drama.Cover
	}
	drama.ID = providerDramaID(sourceHongguo, "novel:"+bookID)
	drama.Source = sourceHongguo
	drama.SourceID = "novel:" + bookID
	serial := mapString(book, "serial_count", "content_chapter_number")
	if serial != "" {
		drama.Remark = "共" + serial + "章"
		drama.TotalEpisode = serial
		drama.EpisodeCount = serial
	}
	items := []map[string]any{}
	seen := map[string]bool{}
	offset := "0"
	for round := 0; round < 40; round++ {
		dir, err := d.hongguoAppRequest(ctx, http.MethodGet, "/reading/bookapi/directory/all_items/v", url.Values{"book_id": {bookID}, "offset": {offset}, "count": {"500"}}, nil)
		if err != nil {
			return Drama{}, nil, err
		}
		rows := anyList(nestedMap(dir, "data")["item_data_list"])
		fresh := 0
		for _, row := range rows {
			item, _ := row.(map[string]any)
			if item == nil {
				continue
			}
			itemID := mapString(item, "item_id")
			if itemID == "" || seen[itemID] {
				continue
			}
			seen[itemID] = true
			items = append(items, item)
			fresh++
		}
		if len(rows) == 0 || fresh == 0 {
			break
		}
		offset = mapString(items[len(items)-1], "item_id")
		if offset == "" {
			break
		}
	}
	if len(items) == 0 {
		return Drama{}, nil, errors.New("小说未返回章节目录")
	}
	toneID, toneErr := hongguoAudioToneID(ctx, d, bookID)
	if toneErr != nil {
		toneID = 80
	}
	chapters := make([]Chapter, 0, len(items))
	for index, item := range items {
		itemID := mapString(item, "item_id")
		title := mapString(item, "title")
		if title == "" {
			title = fmt.Sprintf("第%d章", index+1)
		}
		chapter := Chapter{
			ID:             providerChapterID(sourceHongguo, "novel:"+bookID, itemID),
			Source:         sourceHongguo,
			Title:          title,
			VideoURL:       "novel://hgitem:" + itemID + "?t=" + url.QueryEscape(title),
			CurrentEpisode: rawEpisode(index + 1),
		}
		if toneID > 0 {
			chapter.Routes = []string{fmt.Sprintf("hongguo-audio://%s/%s/%d", bookID, itemID, toneID)}
		}
		chapters = append(chapters, chapter)
	}
	return drama, chapters, nil
}

func (d *Downloader) fetchHongguoAudioDetailHongguo(ctx context.Context, bookID string) (Drama, []Chapter, error) {
	raw, chapters, err := d.fetchHongguoAudioDetail(ctx, bookID)
	if err != nil {
		return Drama{}, nil, err
	}
	raw.ID = providerDramaID(sourceHongguo, "audio:"+bookID)
	raw.Source = sourceHongguo
	raw.SourceID = "audio:" + bookID
	raw.CategoryName = "听书"
	for i := range chapters {
		chapters[i].Source = sourceHongguo
		parts := strings.Split(chapters[i].VideoURL, "/")
		if len(parts) == 4 {
			chapters[i].ID = providerChapterID(sourceHongguo, "audio:"+bookID, parts[2])
		}
	}
	return raw, chapters, nil
}

func (d *Downloader) resolveHongguoNovelMedia(ctx context.Context, task Task) (providerMedia, error) {
	rest := strings.TrimPrefix(task.Chapter.VideoURL, "novel://hgitem:")
	itemID := rest
	title := ""
	if index := strings.Index(rest, "?t="); index >= 0 {
		itemID = rest[:index]
		if decoded, err := url.QueryUnescape(rest[index+3:]); err == nil {
			title = decoded
		}
	}
	if !hongguoNumericID.MatchString(itemID) {
		return providerMedia{}, errors.New("小说章节地址无效")
	}
	text, err := hongguoReaderChapterText(ctx, d, itemID)
	if err != nil {
		return providerMedia{}, err
	}
	safeTitle := strings.NewReplacer("#", "＃", "$", "＄").Replace(title)
	safeText := strings.NewReplacer("#", "＃", "$", "＄").Replace(text)
	payload, err := json.Marshal(map[string]string{"title": safeTitle, "content": safeText})
	if err != nil {
		return providerMedia{}, err
	}
	return providerMedia{URL: "novel://" + string(payload)}, nil
}
