package seku

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

type crackVip struct {
	Token   string `json:"token"`
	Account string `json:"account"`
	Unlock  string `json:"unlock"`
}

type crackSite struct {
	Slot string    `json:"slot"`
	Vip  *crackVip `json:"vip,omitempty"`
}

type crackConfig struct {
	Version int         `json:"version"`
	Sites   []crackSite `json:"sites"`
}

var (
	crackMu  sync.Mutex
	crackCur *crackConfig
)

func crackVipNonEmpty(v *crackVip) bool {
	return v != nil && (v.Token != "" || v.Account != "" || v.Unlock != "")
}

func crackDirPath() string {
	storeMu.Lock()
	defer storeMu.Unlock()
	return storeDir
}

func crackFilePath() string {
	dir := crackDirPath()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, "crackcfg.json")
}

func crackLoadLocked() *crackConfig {
	if crackCur != nil {
		return crackCur
	}
	crackCur = &crackConfig{Version: 1}
	if p := crackFilePath(); p != "" {
		if b, err := os.ReadFile(p); err == nil {
			var saved crackConfig
			if json.Unmarshal(b, &saved) == nil && saved.Version == 1 {
				crackCur = &saved
			}
		}
	}
	return crackCur
}

func crackSaveLocked() {
	if crackCur == nil {
		return
	}
	p := crackFilePath()
	if p == "" {
		return
	}
	b, err := json.Marshal(crackCur)
	if err != nil {
		return
	}
	_ = os.WriteFile(p, b, 0600)
}

func crackValidate(cfg *crackConfig) error {
	if cfg.Version != 1 {
		return fmt.Errorf("crack config: unsupported version %d", cfg.Version)
	}
	seen := map[string]bool{}
	for i, s := range cfg.Sites {
		slot := strings.TrimSpace(s.Slot)
		if slot == "" {
			return fmt.Errorf("crack config: sites[%d] missing slot", i)
		}
		if seen[slot] {
			return fmt.Errorf("crack config: duplicate slot %q", slot)
		}
		seen[slot] = true
		if !crackVipNonEmpty(s.Vip) {
			return fmt.Errorf("crack config: site %q has no vip content", slot)
		}
	}
	return nil
}

func CrackConfigSet(content string) error {
	var cfg crackConfig
	if err := json.Unmarshal([]byte(content), &cfg); err != nil {
		return fmt.Errorf("crack config: invalid JSON: %v", err)
	}
	if err := crackValidate(&cfg); err != nil {
		return err
	}
	crackMu.Lock()
	defer crackMu.Unlock()
	crackCur = &cfg
	crackSaveLocked()
	return nil
}

func CrackConfigSummary() map[string]any {
	crackMu.Lock()
	defer crackMu.Unlock()
	cfg := crackLoadLocked()
	sites := []map[string]any{}
	for _, s := range cfg.Sites {
		sites = append(sites, map[string]any{
			"slot":   s.Slot,
			"hasVip": crackVipNonEmpty(s.Vip),
		})
	}
	return map[string]any{"sites": sites}
}

func crackVipForSlot(slot string) *crackVip {
	crackMu.Lock()
	defer crackMu.Unlock()
	cfg := crackLoadLocked()
	for _, s := range cfg.Sites {
		if s.Slot == slot {
			return s.Vip
		}
	}
	return nil
}

func CrackVipToken(slot string) string {
	if v := crackVipForSlot(slot); v != nil {
		return v.Token
	}
	return ""
}

func CrackVipAccount(slot string) string {
	if v := crackVipForSlot(slot); v != nil {
		return v.Account
	}
	return ""
}

// crackMergedHeaders 统一把加密配置并进请求头。
//
// 删盾后（2026-11-22 用户令）：只做纯拷贝，不再合并任何 shield 配置，
// 调用方（providers.go、sites_g3.go、sites_jar_sihu.go、sites_jar_xhy.go）
// 的调用点保持不变。
func crackMergedHeaders(rawurl string, headers map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range headers {
		out[k] = v
	}
	if _, err := url.Parse(rawurl); err != nil {
		return out
	}
	return out
}
