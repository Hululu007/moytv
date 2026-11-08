package core

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
)

const sourceHGTVMirror = "hgtvmirror"

var hgtvMirrorCategoryID = regexp.MustCompile(`^[a-z0-9][a-z0-9\-/]*$`)

var hgtvMirrorCategoryLink = regexp.MustCompile(`href="/category/([a-z0-9\-/]+)"[^>]*class="[^"]*pc-content-type[^"]*"[^>]*>\s*<span[^>]*>([^<]+)</span>`)

var hgtvMirrorFallbackCategories = []nativeCategory{
	{ID: "real-drama", Name: "真人剧"},
	{ID: "comic-drama", Name: "漫剧"},
	{ID: "ai-drama", Name: "AI剧"},
}

var hgtvMirrorCardLink = regexp.MustCompile(`(?s)<a[^>]*href="/detail\?series_id=(\d+)"[^>]*>(.*?)</a>`)
var hgtvMirrorCardTitle = regexp.MustCompile(`<p[^>]*class="[^"]*pc-title-[^"]*"[^>]*>([^<]+)</p>`)
var hgtvMirrorCardCover = regexp.MustCompile(`<img[^>]*src="([^"]+)"`)
var hgtvMirrorCardSource = regexp.MustCompile(`<source[^>]*srcSet="([^" ]+)"`)
var hgtvMirrorCardAlt = regexp.MustCompile(`<img[^>]*alt="([^"]+)"`)
var hgtvMirrorCardEpisode = regexp.MustCompile(`<p[^>]*class="[^"]*pc-episode-[^"]*"[^>]*>([^<]+)</p>`)

func mirrorRewriteDrama(drama Drama, sourceID string) Drama {
	drama.ID = providerDramaID(sourceHGTVMirror, sourceID)
	drama.Source = sourceHGTVMirror
	drama.SourceID = sourceID
	drama.ChannelName = "红果镜像"
	return drama
}

func parseHGTVMirrorCategories(body string) []nativeCategory {
	seen := map[string]bool{}
	categories := []nativeCategory{}
	for _, match := range hgtvMirrorCategoryLink.FindAllStringSubmatch(body, -1) {
		id := strings.Trim(match[1], "/")
		name := strings.TrimSpace(html.UnescapeString(match[2]))
		if id == "" || name == "" || seen[id] || id == "comic" {
			continue
		}
		seen[id] = true
		categories = append(categories, nativeCategory{ID: id, Name: name})
	}
	return categories
}

func (d *Downloader) fetchHGTVMirrorCategories(ctx context.Context) []nativeCategory {
	body, err := d.fetchProviderText(ctx, hongguoBaseURL+"/category", hongguoBaseURL+"/")
	if err == nil {
		if categories := parseHGTVMirrorCategories(body); len(categories) > 0 {
			return categories
		}
	}
	return hgtvMirrorFallbackCategories
}

func parseHGTVMirrorCards(body string) []Drama {
	seen := map[string]bool{}
	items := []Drama{}
	for _, match := range hgtvMirrorCardLink.FindAllStringSubmatch(body, -1) {
		seriesID := match[1]
		block := match[2]
		if seriesID == "" || seen[seriesID] {
			continue
		}
		title := ""
		if found := hgtvMirrorCardTitle.FindStringSubmatch(block); found != nil {
			title = strings.TrimSpace(html.UnescapeString(found[1]))
		}
		if title == "" {
			if found := hgtvMirrorCardAlt.FindStringSubmatch(block); found != nil {
				title = strings.TrimSpace(html.UnescapeString(found[1]))
				title = strings.TrimSuffix(title, "封面")
				title = strings.TrimSpace(title)
			}
		}
		if title == "" {
			continue
		}
		cover := ""
		if found := hgtvMirrorCardCover.FindStringSubmatch(block); found != nil {
			cover = strings.TrimSpace(found[1])
		}
		if cover == "" {
			if found := hgtvMirrorCardSource.FindStringSubmatch(block); found != nil {
				cover = strings.TrimSpace(found[1])
			}
		}
		remark := ""
		if found := hgtvMirrorCardEpisode.FindStringSubmatch(block); found != nil {
			remark = strings.TrimSpace(html.UnescapeString(found[1]))
		}
		seen[seriesID] = true
		items = append(items, mirrorRewriteDrama(Drama{
			Title:    title,
			Name:     title,
			Cover:    cover,
			CoverURL: cover,
			Remark:   remark,
		}, seriesID))
	}
	return items
}

func (d *Downloader) fetchHGTVMirrorCatalogPage(ctx context.Context, category string, page int) ([]Drama, bool, []nativeFilterGroup, error) {
	category = strings.Trim(category, " /")
	var pageURL string
	if category == "" {
		pageURL = hongguoBaseURL + "/rank/hot-drama"
	} else {
		if page < 1 {
			page = 1
		}
		pageURL = hongguoBaseURL + "/category/" + category + "?page=" + strconv.Itoa(page)
	}
	body, err := d.fetchProviderText(ctx, pageURL, hongguoBaseURL+"/")
	if err != nil {
		return nil, false, nil, err
	}
	items := parseHGTVMirrorCards(body)
	hasMore := category != "" && len(items) >= 20
	return items, hasMore, nil, nil
}

func (d *Downloader) fetchHGTVMirrorDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	drama, chapters, err := d.fetchHGTVWebDetail(ctx, sourceID)
	if err != nil {
		return Drama{}, nil, err
	}
	drama = mirrorRewriteDrama(drama, sourceID)
	for i := range chapters {
		videoID := strings.TrimPrefix(chapters[i].VideoURL, "hongguo-cenc://")
		chapters[i].ID = providerChapterID(sourceHGTVMirror, sourceID, videoID)
		chapters[i].Source = sourceHGTVMirror
		chapters[i].VideoURL = "hgtvmirror://" + videoID
	}
	return drama, chapters, nil
}

func (d *Downloader) searchHGTVMirrorDramas(ctx context.Context, keyword string) ([]Drama, error) {
	items, err := d.searchHGTVDramas(ctx, keyword)
	if err != nil {
		return nil, err
	}
	for i := range items {
		items[i] = mirrorRewriteDrama(items[i], items[i].SourceID)
	}
	return items, nil
}

func (d *Downloader) fetchHGTVMirrorFallbackURL(ctx context.Context, videoID string) (string, error) {
	payload, err := json.Marshal(map[string]any{"item_id": videoID})
	if err != nil {
		return "", err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, hongguoBaseURL+"/api/video/protected/fallback-play-info?aid=8662", bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	request.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36")
	request.Header.Set("Referer", hongguoBaseURL+"/player")
	request.Header.Set("Content-Type", "application/json; charset=utf-8")
	client := d.client
	if client == nil {
		client = http.DefaultClient
	}
	response, err := client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	content, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return "", err
	}
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("红果镜像备用播放接口 HTTP %d", response.StatusCode)
	}
	var decoded map[string]any
	if err := json.Unmarshal(content, &decoded); err != nil {
		return "", err
	}
	mainURL := mapString(decoded, "main_url")
	if mainURL == "" {
		return "", fmt.Errorf("红果镜像备用播放接口未返回播放地址")
	}
	return mainURL, nil
}

func (d *Downloader) resolveHGTVMirrorMedia(ctx context.Context, task Task) (providerMedia, error) {
	source, seriesID, ok := splitProviderDramaID(task.DramaID)
	if !ok || source != sourceHGTVMirror {
		return providerMedia{}, fmt.Errorf("红果镜像章节缺少剧 ID，请刷新剧库后重新加入队列")
	}
	videoID := strings.TrimPrefix(task.Chapter.VideoURL, "hgtvmirror://")
	if !hongguoNumericID.MatchString(videoID) || !hongguoNumericID.MatchString(seriesID) {
		return providerMedia{}, fmt.Errorf("红果镜像章节 ID 无效，请重新获取章节")
	}
	lines := []providerMedia{}
	if media, err := d.resolveHongguoWebMedia(ctx, seriesID, videoID); err == nil {
		flat := media
		flat.Variants = nil
		lines = append(lines, flat)
		for _, variant := range media.Variants {
			variant.Variants = nil
			lines = append(lines, variant)
		}
	} else if err := ctx.Err(); err != nil {
		return providerMedia{}, err
	}
	if fallbackURL, err := d.fetchHGTVMirrorFallbackURL(ctx, videoID); err == nil {
		lines = append(lines, providerMedia{URL: fallbackURL, Referer: hongguoBaseURL + "/"})
	} else if err := ctx.Err(); err != nil {
		return providerMedia{}, err
	}
	lines = append(lines, providerMedia{
		URL:     hongguoBaseURL + "/video/public/" + videoID + "/360p.mp4",
		Referer: hongguoBaseURL + "/",
	})
	media := lines[0]
	media.Variants = lines
	return media, nil
}
