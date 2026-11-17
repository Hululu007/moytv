package core

// 红果(新)自检诊断分类：py _diag（行 1384-1449）的 Go 版。
//
// 6 项检查与 py 一一对应：1 签名算法 / 2 官网连通 / 3 播放模型 / 4 解链 / 5 直链取流 /
// 6 头条精选，另附环境与设备号两行。检查失败不返回错误，而是把 FAIL 写进条目结果里——
// 与 py 一致（诊断分类本身就是用来看哪一步断了的）。
// 注意：第 3 项会真实触发设备注册与播放模型请求，与一次真实取流等价；打开诊断分类即计一次。

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"time"
)

const hongguoNewDiagSeriesID = "7671966197985856536"
const hongguoNewDiagVideoID = "7671977925326949400"

// hongguoNewDiagItems：返回诊断条目（不可播，详情会报错，见 fetchHongguoNewDetail）。
func (downloader *Downloader) hongguoNewDiagItems(ctx context.Context) ([]Drama, error) {
	type check struct {
		name   string
		result string
	}
	var checks []check

	// 1 签名算法：对 realistic 的模型请求跑一遍分支 0 选票 + 播放器签名头，X-Gorgon 非空即过。
	// 注意：Medusa 哈希的分支 1 查表要读 sixGodBranchOne，而这张表只在 sixGodNewAESV3 里
	// 惰性加载（sixGodTables，sync.Once）；新进程里第一次签名若恰好落到分支 1 且表未加载，
	// 就会在 sixGodBranch1TableF 越界 panic（2026-11-17 活测实证：[32768:0]）。真实取流链
	// 路在签名前一般已走过设备注册等加载过表的步骤，诊断页是单机自检、可能成为进程内第一
	// 次签名，故 helper 内先显式调 sixGodTables() 再签名，并保留 recover 兜底。
	start := time.Now()
	if ok, detail := hongguoNewDiagSignCheck(); ok {
		checks = append(checks, check{"1 签名算法", fmt.Sprintf("OK %dms", time.Since(start).Milliseconds())})
	} else {
		checks = append(checks, check{"1 签名算法", "FAIL " + detail})
	}

	// 2 官网连通：拉详情页，报 KB 数。
	if body, err := downloader.fetchProviderText(ctx, hongguoBaseURL+"/detail?series_id="+hongguoNewDiagSeriesID, hongguoBaseURL+"/"); err != nil {
		checks = append(checks, check{"2 官网连通", "FAIL " + publicError(err).Error()})
	} else {
		checks = append(checks, check{"2 官网连通", fmt.Sprintf("OK %dKB", len(body)/1024)})
	}

	// 3 播放模型：真实取模型，报档位数。
	var media providerMedia
	mediaOK := false
	start = time.Now()
	if resolved, err := downloader.resolveHongguoAppMedia(ctx, hongguoNewDiagVideoID); err != nil {
		checks = append(checks, check{"3 播放模型", "FAIL " + publicError(err).Error()})
	} else {
		media, mediaOK = resolved, true
		defs := 1 + len(resolved.Variants)
		checks = append(checks, check{"3 播放模型", fmt.Sprintf("OK %d档 %dms", defs, time.Since(start).Milliseconds())})
	}

	// 4 解链 + 5 直链取流：只在模型成功时跑。
	if mediaOK {
		qualities := map[int]bool{}
		for _, variant := range append([]providerMedia{media}, media.Variants...) {
			if variant.Quality > 0 {
				qualities[variant.Quality] = true
			}
		}
		checks = append(checks, check{"4 解链", fmt.Sprintf("OK %d档", len(qualities))})
		status, ftyp := downloader.hongguoNewDiagRangeCheck(ctx, media.URL, media.Referer)
		checks = append(checks, check{"5 直链取流", fmt.Sprintf("%s ftyp=%v", status, ftyp)})
	}

	// 6 头条精选：强制刷新一次推荐流，报条数。
	start = time.Now()
	if items, err := downloader.hongguoNewToutiaoList(ctx, true); err != nil {
		checks = append(checks, check{"6 头条精选", "FAIL " + publicError(err).Error()})
	} else {
		checks = append(checks, check{"6 头条精选", fmt.Sprintf("OK %d条 %dms", len(items), time.Since(start).Milliseconds())})
	}

	checks = append(checks, check{"环境", "Go 核心 | CENC 中继流式解密 | 诊断分类"})
	checks = append(checks, check{"设备号", firstNonEmpty(downloader.hongguoDeviceID(), "(未注册)")})

	items := make([]Drama, 0, len(checks))
	for i, row := range checks {
		sourceID := "diag" + strconv.Itoa(i)
		items = append(items, Drama{
			ID: providerDramaID(sourceHongguoNew, sourceID), Source: sourceHongguoNew, SourceID: sourceID,
			Title: row.name + "  " + row.result, Name: row.name + "  " + row.result,
			CategoryName: "自检诊断", ChannelName: hongguoNewChannelName, Remark: row.result,
		})
	}
	return items, nil
}

// hongguoNewDiagSignCheck：离线签名自检。构造与真实模型请求同形的请求（真实 URL、
// 完整查询参数、非空 body、占位设备号），跑一遍分支 0 选票 + 全套签名头；不发任何网络请求。
// 返回 (ok, detail)。先显式加载签名表（见上条注释），再签名；recover 兜底：万一 panic
// 也只记 FAIL，不向上传播，诊断页绝不能 crash。
func hongguoNewDiagSignCheck() (ok bool, detail string) {
	defer func() {
		if recovered := recover(); recovered != nil {
			ok, detail = false, fmt.Sprintf("签名 panic 已捕获: %v", recovered)
		}
	}()
	if err := sixGodTables(); err != nil {
		return false, "签名表加载失败: " + err.Error()
	}
	rawURL := "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/" +
		"?aid=8662&device_id=7311111111111111111&version_code=74332&version_name=7.4.3.32" +
		"&device_platform=android&os_version=14&channel=hongguo"
	body := []byte(`{"mixed_video_id_map":{"1004":["7671977925326949400"]}}`)
	request, err := http.NewRequest(http.MethodPost, rawURL, nil)
	if err != nil {
		return false, "构造请求失败"
	}
	query := request.URL.Query()
	hongguoPrepareSignedRequest(request, query, body, time.Now(), true, "7311111111111111111")
	if request.Header.Get("X-Gorgon") == "" || request.Header.Get("X-Helios") == "" ||
		request.Header.Get("X-Argus") == "" || request.Header.Get("X-Ladon") == "" {
		return false, "签名头缺失"
	}
	return true, ""
}

// hongguoNewDiagRangeCheck：Range 取前 64 字节，返回状态与 ftyp 头判定。
func (downloader *Downloader) hongguoNewDiagRangeCheck(ctx context.Context, rawURL, referer string) (string, bool) {
	if !isProviderHTTPMediaURL(rawURL) {
		return "无地址", false
	}
	callCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(callCtx, http.MethodGet, rawURL, nil)
	if err != nil {
		return "FAIL", false
	}
	request.Header.Set("Range", "bytes=0-63")
	request.Header.Set("User-Agent", hongguoAppUserAgent)
	if referer != "" {
		request.Header.Set("Referer", referer)
	}
	client := downloader.client
	if client == nil {
		client = http.DefaultClient
	}
	response, err := client.Do(request)
	if err != nil {
		return "FAIL", false
	}
	defer response.Body.Close()
	head, _ := io.ReadAll(io.LimitReader(response.Body, 8))
	ftyp := len(head) >= 8 && string(head[4:8]) == "ftyp"
	return strconv.Itoa(response.StatusCode), ftyp
}
