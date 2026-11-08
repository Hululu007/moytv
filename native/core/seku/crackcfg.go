package seku

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

type crackShield struct {
	Hosts       []string          `json:"hosts"`
	CfClearance string            `json:"cf_clearance"`
	Cookies     string            `json:"cookies"`
	Headers     map[string]string `json:"headers"`
	UserAgent   string            `json:"userAgent"`
}

type crackVip struct {
	Token   string `json:"token"`
	Account string `json:"account"`
	Unlock  string `json:"unlock"`
}

type crackSite struct {
	Slot   string       `json:"slot"`
	Shield *crackShield `json:"shield,omitempty"`
	Vip    *crackVip    `json:"vip,omitempty"`
}

type crackConfig struct {
	Version int         `json:"version"`
	Sites   []crackSite `json:"sites"`
}

var (
	crackMu  sync.Mutex
	crackCur *crackConfig
)

func crackShieldNonEmpty(s *crackShield) bool {
	if s == nil {
		return false
	}
	if len(s.Hosts) > 0 || s.CfClearance != "" || s.Cookies != "" || s.UserAgent != "" {
		return true
	}
	for _, v := range s.Headers {
		if v != "" {
			return true
		}
	}
	return false
}

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
		if !crackShieldNonEmpty(s.Shield) && !crackVipNonEmpty(s.Vip) {
			return fmt.Errorf("crack config: site %q has neither shield nor vip content", slot)
		}
		if s.Shield != nil {
			for _, h := range s.Shield.Hosts {
				if strings.TrimSpace(h) == "" {
					return fmt.Errorf("crack config: site %q has an empty shield host", slot)
				}
			}
			for k, v := range s.Shield.Headers {
				if strings.TrimSpace(k) == "" || strings.TrimSpace(v) == "" {
					return fmt.Errorf("crack config: site %q has an empty shield header", slot)
				}
			}
		}
	}
	return nil
}

func crackHostsOf(cfg *crackConfig) map[string]bool {
	out := map[string]bool{}
	for _, s := range cfg.Sites {
		if s.Shield == nil {
			continue
		}
		for _, h := range s.Shield.Hosts {
			h = strings.ToLower(strings.TrimSpace(h))
			if h != "" {
				out[h] = true
			}
		}
	}
	return out
}

func CrackConfigSet(content string) (removedHosts []string, err error) {
	var cfg crackConfig
	if err := json.Unmarshal([]byte(content), &cfg); err != nil {
		return nil, fmt.Errorf("crack config: invalid JSON: %v", err)
	}
	if err := crackValidate(&cfg); err != nil {
		return nil, err
	}
	crackMu.Lock()
	defer crackMu.Unlock()
	oldHosts := crackHostsOf(crackLoadLocked())
	newHosts := crackHostsOf(&cfg)
	for h := range oldHosts {
		if !newHosts[h] {
			removedHosts = append(removedHosts, h)
		}
	}
	sort.Strings(removedHosts)
	crackCur = &cfg
	crackSaveLocked()
	return removedHosts, nil
}

func CrackConfigSummary() map[string]any {
	crackMu.Lock()
	defer crackMu.Unlock()
	cfg := crackLoadLocked()
	sites := []map[string]any{}
	for _, s := range cfg.Sites {
		sites = append(sites, map[string]any{
			"slot":      s.Slot,
			"hasShield": crackShieldNonEmpty(s.Shield),
			"hasVip":    crackVipNonEmpty(s.Vip),
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

func crackSplitCookies(value string) []string {
	parts := strings.Split(value, ";")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func crackCookieContains(cookies, part string) bool {
	for _, p := range crackSplitCookies(cookies) {
		if p == part {
			return true
		}
	}
	return false
}

func crackShieldForHost(host string) (cookie string, headers map[string]string, ua string, ok bool) {
	host = strings.ToLower(strings.TrimSpace(host))
	if host == "" {
		return "", nil, "", false
	}
	crackMu.Lock()
	defer crackMu.Unlock()
	cfg := crackLoadLocked()
	merged := map[string]string{}
	var parts []string
	found := false
	for _, s := range cfg.Sites {
		if s.Shield == nil {
			continue
		}
		match := false
		for _, h := range s.Shield.Hosts {
			if strings.ToLower(strings.TrimSpace(h)) == host {
				match = true
				break
			}
		}
		if !match {
			continue
		}
		found = true
		if cf := strings.TrimSpace(s.Shield.CfClearance); cf != "" {
			if !strings.HasPrefix(cf, "cf_clearance=") {
				cf = "cf_clearance=" + cf
			}
			parts = append(parts, cf)
		}
		parts = append(parts, crackSplitCookies(s.Shield.Cookies)...)
		for k, v := range s.Shield.Headers {
			merged[k] = v
		}
		if ua == "" {
			ua = s.Shield.UserAgent
		}
	}
	if !found {
		return "", nil, "", false
	}
	return strings.Join(parts, "; "), merged, ua, true
}

func crackMergedHeaders(rawurl string, headers map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range headers {
		out[k] = v
	}
	u, err := url.Parse(rawurl)
	if err != nil || u.Hostname() == "" {
		return out
	}
	cookie, extra, ua, ok := crackShieldForHost(u.Hostname())
	if !ok {
		return out
	}
	if cookie != "" {
		cookieKey := ""
		for k := range out {
			if strings.EqualFold(k, "Cookie") {
				cookieKey = k
				break
			}
		}
		if cookieKey == "" {
			out["Cookie"] = cookie
		} else {
			existing := out[cookieKey]
			add := make([]string, 0)
			for _, p := range crackSplitCookies(cookie) {
				if !crackCookieContains(existing, p) {
					add = append(add, p)
				}
			}
			if len(add) > 0 {
				out[cookieKey] = existing + "; " + strings.Join(add, "; ")
			}
		}
	}
	for k, v := range extra {
		out[k] = v
	}
	if ua != "" {
		out["User-Agent"] = ua
	}
	return out
}

type CrackDownloaderMapping struct {
	Host   string
	Cookie string
	UA     string
}

func CrackDownloaderMappings() []CrackDownloaderMapping {
	crackMu.Lock()
	defer crackMu.Unlock()
	cfg := crackLoadLocked()
	var out []CrackDownloaderMapping
	for _, s := range cfg.Sites {
		if s.Shield == nil {
			continue
		}
		cf := strings.TrimSpace(s.Shield.CfClearance)
		if cf == "" {
			continue
		}
		if !strings.HasPrefix(cf, "cf_clearance=") {
			cf = "cf_clearance=" + cf
		}
		for _, h := range s.Shield.Hosts {
			h = strings.ToLower(strings.TrimSpace(h))
			if h == "" {
				continue
			}
			out = append(out, CrackDownloaderMapping{Host: h, Cookie: cf, UA: s.Shield.UserAgent})
		}
	}
	return out
}
