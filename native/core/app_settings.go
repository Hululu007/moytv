package core

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type nativeResourceSettings struct {
	ProxyMode           string `json:"proxyMode"`
	ProxyURL            string `json:"proxyUrl"`
	CatalogConcurrency  int    `json:"catalogConcurrency"`
	CatalogIntervalMS   int    `json:"catalogIntervalMs"`
	DownloadConcurrency int    `json:"downloadConcurrency"`
	DownloadBySource    bool   `json:"downloadBySource"`
	Warning             string `json:"warning,omitempty"`
	SystemProxyStatus   string `json:"systemProxyStatus,omitempty"`
}

func defaultResourceSettings() nativeResourceSettings {
	return nativeResourceSettings{ProxyMode: "auto", CatalogConcurrency: 3, CatalogIntervalMS: 250, DownloadConcurrency: 2}
}

func (settings nativeResourceSettings) validate() error {
	if settings.CatalogConcurrency < 1 || settings.CatalogConcurrency > 6 ||
		settings.CatalogIntervalMS < 0 || settings.CatalogIntervalMS > 5000 ||
		settings.DownloadConcurrency < 1 || settings.DownloadConcurrency > 6 {
		return errors.New("并发应为 1 至 6，请求间隔应为 0 至 5000 毫秒")
	}
	if settings.ProxyMode != "auto" && settings.ProxyMode != "direct" && settings.ProxyMode != "manual" {
		return errors.New("代理模式无效")
	}
	if settings.ProxyMode == "manual" || settings.ProxyURL != "" {
		if len(settings.ProxyURL) > 2048 {
			return errors.New("代理地址过长")
		}
		parsed, err := url.Parse(settings.ProxyURL)
		if err != nil || parsed.Hostname() == "" || parsed.Fragment != "" || parsed.RawQuery != "" ||
			(parsed.Path != "" && parsed.Path != "/") ||
			(parsed.Scheme != "http" && parsed.Scheme != "https" && parsed.Scheme != "socks5" && parsed.Scheme != "socks5h") {
			return errors.New("请输入有效的 HTTP、HTTPS 或 SOCKS5 代理地址")
		}
		if port := parsed.Port(); port != "" {
			number, err := strconv.Atoi(port)
			if err != nil || number < 1 || number > 65535 {
				return errors.New("代理端口无效")
			}
		}
	}
	return nil
}

type proxyRouter struct {
	mu             sync.RWMutex
	mode           string
	manual         *url.URL
	system         nativeSystemProxy
	systemRead     time.Time
	systemOverride bool
	// egress 是 Dart 出口决策点的覆盖地址（代理内核 / SOCKS5 转发器 /
	// 手填地址），非空时优先于 mode/manual/system 生效；回环目标不受影响。
	// 它是运行时覆盖，不落盘；applyResourceSettings 刻意不碰它，Dart 侧
	// 清掉覆盖后自动回到用户原来的模式与手填地址。
	egress *url.URL
}

func (router *proxyRouter) proxy(request *http.Request) (*url.URL, error) {
	if request.URL.Hostname() == "127.0.0.1" || request.URL.Hostname() == "localhost" || request.URL.Hostname() == "::1" {
		return nil, nil
	}
	router.mu.RLock()
	egress, mode, manual := router.egress, router.mode, router.manual
	router.mu.RUnlock()
	if egress != nil {
		return egress, nil
	}
	switch mode {
	case "direct":
		return nil, nil
	case "manual":
		return manual, nil
	}
	return router.systemSettings().resolve(request)
}

func (engine *nativeEngine) loadResourceSettings() {
	settings := defaultResourceSettings()
	file := filepath.Join(engine.directory, "resource-settings.json")
	info, err := os.Stat(file)
	if err == nil {
		var stored nativeResourceSettings
		if info.Mode().IsRegular() && info.Size() <= 16384 {
			if data, readErr := os.ReadFile(file); readErr == nil && json.Unmarshal(data, &stored) == nil && stored.validate() == nil {
				settings = stored
			} else {
				settings.Warning = "网络与下载设置无法读取，已使用默认值，请重新保存设置"
			}
		} else {
			settings.Warning = "网络与下载设置无效，已使用默认值，请重新保存设置"
		}
	} else if !os.IsNotExist(err) {
		settings.Warning = "网络与下载设置无法读取，已使用默认值，请重新保存设置"
	}
	engine.settings = settings
	engine.applyResourceSettings(settings)
}

func (engine *nativeEngine) resourceSettings() nativeResourceSettings {
	engine.settingsMu.Lock()
	defer engine.settingsMu.Unlock()
	if engine.settings.ProxyMode == "" {
		return defaultResourceSettings()
	}
	settings := engine.settings
	system := engine.downloader.proxyRouter.systemSettings()
	settings.SystemProxyStatus = "自动读取系统静态代理及环境变量"
	if system.PAC && system.HTTP == "" && system.HTTPS == "" {
		settings.SystemProxyStatus = "检测到系统自动代理脚本；请配置手动代理或选择直连"
	} else if system.HTTP != "" || system.HTTPS != "" {
		settings.SystemProxyStatus = "已读取系统静态代理"
	}
	return settings
}

func (engine *nativeEngine) applyResourceSettings(settings nativeResourceSettings) {
	router := engine.downloader.proxyRouter
	manual, _ := url.Parse(settings.ProxyURL)
	router.mu.Lock()
	// 只写 mode/manual：egress 覆盖是 Dart 出口决策点的运行时状态，
	// 用户保存资源设置不该把它清掉，决策点自己负责同步与恢复。
	router.mode, router.manual = settings.ProxyMode, manual
	router.mu.Unlock()
	limiter := engine.downloader.limiter
	limiter.mu.Lock()
	limiter.concurrency = settings.CatalogConcurrency
	limiter.interval = time.Duration(settings.CatalogIntervalMS) * time.Millisecond
	limiter.notifyLocked()
	limiter.mu.Unlock()
	if engine.downloads != nil {
		engine.downloads.mu.Lock()
		engine.downloads.concurrency = settings.DownloadConcurrency
		engine.downloads.bySource = settings.DownloadBySource
		engine.downloads.scheduleLocked()
		engine.downloads.mu.Unlock()
	}
}

func (engine *nativeEngine) saveResourceSettings(settings nativeResourceSettings) (nativeResourceSettings, error) {
	settings.ProxyURL = strings.TrimSpace(settings.ProxyURL)
	settings.Warning = ""
	settings.SystemProxyStatus = ""
	if err := settings.validate(); err != nil {
		return nativeResourceSettings{}, err
	}
	engine.settingsMu.Lock()
	defer engine.settingsMu.Unlock()
	data, err := json.Marshal(settings)
	if err == nil {
		err = nativeDownloadWrite(filepath.Join(engine.directory, "resource-settings.json"), data)
	}
	if err != nil {
		return nativeResourceSettings{}, errors.New("未能保存网络与下载设置，原设置保持不变")
	}
	engine.settings = settings
	engine.applyResourceSettings(settings)
	engine.downloader.client.CloseIdleConnections()
	return settings, nil
}

// setEgressProxy 设置或清除 Dart 出口决策点的代理覆盖地址。
// 空地址表示清除覆盖，之后按用户保存的资源设置（mode/manual/system）走。
// 非空地址按资源设置同样的规则校验，非法地址拒绝且保持原覆盖不变。
// 地址变化时关闭空闲连接，让已建连接不继续走旧出口。
func (engine *nativeEngine) setEgressProxy(address string) error {
	address = strings.TrimSpace(address)
	var parsed *url.URL
	if address != "" {
		settings := defaultResourceSettings()
		settings.ProxyMode, settings.ProxyURL = "manual", address
		if err := settings.validate(); err != nil {
			return err
		}
		parsed, _ = url.Parse(address)
	}
	router := engine.downloader.proxyRouter
	router.mu.Lock()
	changed := (router.egress == nil) != (parsed == nil) ||
		(router.egress != nil && parsed != nil && router.egress.String() != parsed.String())
	router.egress = parsed
	router.mu.Unlock()
	if changed {
		engine.downloader.client.CloseIdleConnections()
	}
	return nil
}
