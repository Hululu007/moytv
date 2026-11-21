package core

import (
	"errors"
	"strconv"
	"strings"
)

var buildAllSources = "false"

var coreBuild = "0"

func coreBuildNumber() int {
	n, err := strconv.Atoi(strings.TrimSpace(coreBuild))
	if err != nil || n < 0 {
		return 0
	}
	return n
}

func coreInfoData() map[string]any {
	return map[string]any{
		"build":      coreBuildNumber(),
		"allSources": buildAllSources == "true",
	}
}

var errNativeBuildSource = errors.New("当前版本不包含此站源")

func nativeSourceAvailable(source string) bool {
	source = canonicalProviderSource(source)
	if source == sourceHongguo {
		return true
	}
	if isCustomMaccmsSource(source) {
		return isHuangguoProviderSource(source)
	}
	return buildAllSources == "true" && isHuangguoProviderSource(source)
}

func nativeDramaAvailable(drama nativeDrama) bool {
	source, _, valid := splitProviderDramaID(drama.ID)
	return valid && nativeSourceAvailable(source) &&
		(drama.Source == "" || canonicalProviderSource(drama.Source) == source)
}

// nativeDramaCoverUsable：剧集自带绝对封面地址（本地库 pic_url）就算
// 可用，与站源是否内置无关。
func nativeDramaCoverUsable(drama nativeDrama) bool {
	cover := strings.TrimSpace(drama.Cover)
	return strings.HasPrefix(cover, "http://") || strings.HasPrefix(cover, "https://")
}

func nativeChapterAvailable(drama nativeDrama, chapter Chapter) bool {
	if !nativeDramaAvailable(drama) {
		return false
	}
	source, _, _ := splitProviderDramaID(drama.ID)
	if chapter.Source != "" && canonicalProviderSource(chapter.Source) != source {
		return false
	}
	if chapterSource, _, valid := splitProviderDramaID(chapter.ID); valid && chapterSource != source {
		return false
	}
	return true
}

func nativeDownloadAvailable(job nativeDownloadJob) bool {
	return nativeChapterAvailable(job.Drama, job.Chapter)
}

func nativeAuthorizeInput(input nativeInput) error {
	switch input.Action {
	case "recommendations", "cachedRecommendations", "suggestions", "danmaku", "comments":
		if !nativeSourceAvailable(sourceHongguo) {
			return errNativeBuildSource
		}
	case "rankings":
		board, found := findRankingBoard(input.Board)
		if !found || !nativeSourceAvailable(board.Source) {
			return errNativeBuildSource
		}
	case "catalog", "cached", "categories", "sourceStatus", "sourceJob", "cancelSourceJob":
		if !nativeSourceAvailable(input.Source) {
			return errNativeBuildSource
		}
		if input.Action == "sourceJob" && input.Drama.ID != "" &&
			(!nativeDramaAvailable(input.Drama) || sourceFromDramaID(input.Drama.ID) != canonicalProviderSource(input.Source)) {
			return errNativeBuildSource
		}
	case "searchAcross":
		if len(input.Sources) == 0 {
			return errNativeBuildSource
		}
		for _, source := range input.Sources {
			if !nativeSourceAvailable(canonicalProviderSource(source)) {
				return errNativeBuildSource
			}
		}
	case "cover", "prepareCover":
		// 封面只要自带绝对地址就放行：女优库/影视库的行来自本地 db
		// （source 是 vod_play_from 或 'db'），不是内置站源，但图是真的，
		// 不该因为「站源未内置」整页留灰块。
		if !nativeDramaAvailable(input.Drama) && !nativeDramaCoverUsable(input.Drama) {
			return errNativeBuildSource
		}
	case "resolve", "preload":
		// 集地址自带直链（direct + http(s)）的照样放行：本地库的
		// m3u8_url 直接播，不依赖内置站源。
		if directMediaURL(input.Chapter) != "" {
			return nil
		}
		if !nativeDramaAvailable(input.Drama) {
			return errNativeBuildSource
		}
		if !nativeChapterAvailable(input.Drama, input.Chapter) {
			return errNativeBuildSource
		}
	case "detail", "metadata", "enqueueDownloads", "localPlayback":
		if !nativeDramaAvailable(input.Drama) {
			return errNativeBuildSource
		}
	}
	return nil
}
