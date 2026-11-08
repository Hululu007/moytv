package core

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const sourceHongguoAudio = "hongguo_audio"

func hongguoAudioRewriteDrama(drama Drama, sourceID string) Drama {
	drama.ID = providerDramaID(sourceHongguoAudio, sourceID)
	drama.Source = sourceHongguoAudio
	drama.SourceID = sourceID
	drama.ChannelName = "红果听书"
	return drama
}

func hongguoAudioBookFromAny(row map[string]any) Drama {
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
	drama := Drama{
		Title: title, Name: title, Desc: intro, Intro: intro,
		Cover: cover, CoverURL: cover, CategoryName: "听书",
		Remark: remark, TotalEpisode: serial, EpisodeCount: serial,
	}
	return hongguoAudioRewriteDrama(drama, bookID)
}

func hongguoAudioCollectBooks(value any, seen map[string]bool, out *[]Drama) {
	switch node := value.(type) {
	case map[string]any:
		if drama := hongguoAudioBookFromAny(node); drama.ID != "" && !seen[drama.SourceID] {
			seen[drama.SourceID] = true
			*out = append(*out, drama)
		}
		for _, child := range node {
			hongguoAudioCollectBooks(child, seen, out)
		}
	case []any:
		for _, child := range node {
			hongguoAudioCollectBooks(child, seen, out)
		}
	}
}

func (d *Downloader) fetchHongguoAudioCatalogPage(ctx context.Context, category string, page int) ([]Drama, bool, error) {
	if page != 1 {
		return []Drama{}, false, nil
	}
	if category != "" && category != "all" && category != "全部" && category != "audio" && category != "听书" {
		return nil, false, errors.New("红果听书分类无效")
	}
	result, err := d.hongguoAppRequest(ctx, http.MethodGet, "/reading/bookapi/bookmall/tab/v", url.Values{"tab_type": {"5"}}, nil)
	if err != nil {
		return nil, false, err
	}
	seen := map[string]bool{}
	items := []Drama{}
	hongguoAudioCollectBooks(result, seen, &items)
	if len(items) == 0 {
		return nil, false, errors.New("红果听书书城未返回书目")
	}
	return items, false, nil
}

func hongguoAudioToneID(ctx context.Context, d *Downloader, bookID string) (int, error) {
	result, err := d.hongguoAppRequest(ctx, http.MethodGet, "/reading/bookapi/audio/toneinfo/", url.Values{"book_id": {bookID}}, nil)
	if err == nil {
		data := nestedMap(result, "data")
		for _, tone := range anyList(data["tts_tones"]) {
			if toneMap, ok := tone.(map[string]any); ok {
				if id, parseErr := strconv.Atoi(mapString(toneMap, "id")); parseErr == nil && id > 0 {
					return id, nil
				}
			}
		}
		if id, parseErr := strconv.Atoi(mapString(data, "recommend_tone")); parseErr == nil && id > 0 {
			return id, nil
		}
	}
	detail, detailErr := d.hongguoAppRequest(ctx, http.MethodGet, "/reading/bookapi/audio/detail/", url.Values{"book_id": {bookID}}, nil)
	if detailErr != nil {
		if err != nil {
			return 0, err
		}
		return 0, detailErr
	}
	for _, part := range strings.Split(mapString(nestedMap(detail, "data"), "tones"), ",") {
		if id, parseErr := strconv.Atoi(strings.TrimSpace(part)); parseErr == nil && id > 0 {
			return id, nil
		}
	}
	return 0, errors.New("红果听书未返回可用音色")
}

func (d *Downloader) fetchHongguoAudioDetail(ctx context.Context, bookID string) (Drama, []Chapter, error) {
	if !hongguoNumericID.MatchString(bookID) {
		return Drama{}, nil, errors.New("红果听书 ID 无效")
	}
	result, err := d.hongguoAppRequest(ctx, http.MethodGet, "/reading/bookapi/audio/detail/", url.Values{"book_id": {bookID}}, nil)
	if err != nil {
		return Drama{}, nil, err
	}
	book := nestedMap(result, "data")
	if mapString(book, "book_id") != "" && mapString(book, "book_id") != bookID {
		return Drama{}, nil, errors.New("红果听书未返回所请求的书")
	}
	drama := hongguoAudioBookFromAny(book)
	if drama.ID == "" {
		drama = hongguoAudioRewriteDrama(Drama{
			Title: mapString(book, "book_name", "book_short_name"),
			Name:  mapString(book, "book_name", "book_short_name"),
			Desc:  mapString(book, "abstract", "book_abstract_v2"),
			Intro: mapString(book, "abstract", "book_abstract_v2"),
			Cover: mapString(book, "thumb_url", "detail_page_thumb_url"),
		}, bookID)
	}
	drama.CoverURL = drama.Cover
	serial := mapString(book, "serial_count", "content_chapter_number")
	if serial != "" {
		drama.Remark = "共" + serial + "章"
		drama.TotalEpisode = serial
		drama.EpisodeCount = serial
	}
	toneID, err := hongguoAudioToneID(ctx, d, bookID)
	if err != nil {
		return Drama{}, nil, err
	}
	dir, err := d.hongguoAppRequest(ctx, http.MethodGet, "/reading/bookapi/directory/all_items/v", url.Values{"book_id": {bookID}, "offset": {"0"}, "count": {"500"}}, nil)
	if err != nil {
		return Drama{}, nil, err
	}
	rows := anyList(nestedMap(dir, "data")["item_data_list"])
	if len(rows) == 0 {
		return Drama{}, nil, errors.New("红果听书未返回章节目录")
	}
	chapters := make([]Chapter, 0, len(rows))
	seen := map[string]bool{}
	for index, row := range rows {
		item, _ := row.(map[string]any)
		if item == nil {
			continue
		}
		itemID := mapString(item, "item_id")
		if !hongguoNumericID.MatchString(itemID) || seen[itemID] {
			continue
		}
		seen[itemID] = true
		title := mapString(item, "title")
		if title == "" {
			title = fmt.Sprintf("第%d章", index+1)
		}
		chapters = append(chapters, Chapter{
			ID:             providerChapterID(sourceHongguoAudio, bookID, itemID),
			Source:         sourceHongguoAudio,
			Title:          title,
			VideoURL:       fmt.Sprintf("hongguo-audio://%s/%s/%d", bookID, itemID, toneID),
			CurrentEpisode: rawEpisode(index + 1),
		})
	}
	if len(chapters) == 0 {
		return Drama{}, nil, errors.New("红果听书章节目录为空")
	}
	return drama, chapters, nil
}

func (d *Downloader) resolveHongguoAudioMedia(ctx context.Context, task Task) (providerMedia, error) {
	rest := strings.TrimPrefix(task.Chapter.VideoURL, "hongguo-audio://")
	parts := strings.Split(rest, "/")
	if len(parts) != 3 || !hongguoNumericID.MatchString(parts[0]) || !hongguoNumericID.MatchString(parts[1]) {
		return providerMedia{}, errors.New("红果听书章节地址无效")
	}
	bookID, itemID, toneText := parts[0], parts[1], parts[2]
	toneID, err := strconv.Atoi(toneText)
	if err != nil || toneID <= 0 {
		return providerMedia{}, errors.New("红果听书音色无效")
	}
	payload := map[string]any{"book_id": jsonNumber(bookID), "item_id": jsonNumber(itemID), "tone_id": toneID, "req_type": 0}
	result, err := d.hongguoAppRequest(ctx, http.MethodPost, "/reading/bookapi/audio/playurl/", nil, payload)
	if err != nil {
		return providerMedia{}, err
	}
	data := nestedMap(result, "data")
	mainURL := mapString(data, "main_url")
	encKey := mapString(data, "encryption_key")
	if !isProviderHTTPMediaURL(mainURL) || encKey == "" {
		return providerMedia{}, errors.New("红果听书未返回有效播放地址")
	}
	key, err := hongguoContentKey(encKey)
	if err != nil {
		return providerMedia{}, err
	}
	duration, _ := strconv.ParseFloat(mapString(data, "duration"), 64)
	return providerMedia{
		URL: mainURL, Referer: "https://novel.snssdk.com/",
		CENCKey: key, Audio: true, Duration: time.Duration(duration * float64(time.Second)),
	}, nil
}

func jsonNumber(text string) any {
	if value, err := strconv.ParseInt(text, 10, 64); err == nil {
		return value
	}
	return text
}
