package core

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type shieldClearance struct {
	Cookie  string    `json:"cookie"`
	UA      string    `json:"ua"`
	Updated time.Time `json:"updated"`
}

type shieldChallenge struct {
	Host string    `json:"host"`
	URL  string    `json:"url"`
	At   time.Time `json:"at"`
}

func shieldNormalizeHost(value string) string {
	value = strings.TrimSpace(value)
	if strings.Contains(value, "://") {
		if parsed, err := url.Parse(value); err == nil {
			value = parsed.Host
		}
	}
	if parsed, err := url.Parse("//" + value); err == nil && parsed.Hostname() != "" {
		return strings.ToLower(parsed.Hostname())
	}
	return strings.ToLower(value)
}

func (d *Downloader) shieldStorePath() string {
	if d.cfg.dataDir == "" {
		return ""
	}
	return filepath.Join(d.cfg.dataDir, "shield_clearance.json")
}

func (d *Downloader) loadShieldClearances() {
	d.shieldMu.Lock()
	defer d.shieldMu.Unlock()
	d.shieldInitLocked()
	path := d.shieldStorePath()
	if path == "" {
		return
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return
	}
	stored := map[string]shieldClearance{}
	if json.Unmarshal(body, &stored) == nil {
		for host, entry := range stored {
			d.shieldClearances[shieldNormalizeHost(host)] = entry
		}
	}
}

func (d *Downloader) shieldInitLocked() {
	if d.shieldClearances == nil {
		d.shieldClearances = map[string]shieldClearance{}
	}
	if d.shieldChallenges == nil {
		d.shieldChallenges = map[string]shieldChallenge{}
	}
}

func (d *Downloader) persistShieldClearancesLocked() {
	path := d.shieldStorePath()
	if path == "" {
		return
	}
	body, err := json.Marshal(d.shieldClearances)
	if err != nil {
		return
	}
	_ = os.WriteFile(path, body, 0600)
}

func (d *Downloader) recordShieldChallenge(rawurl string) {
	parsed, err := url.Parse(rawurl)
	if err != nil || parsed.Hostname() == "" {
		return
	}
	host := strings.ToLower(parsed.Hostname())
	d.shieldMu.Lock()
	d.shieldInitLocked()
	d.shieldChallenges[host] = shieldChallenge{Host: host, URL: rawurl, At: time.Now()}
	d.shieldMu.Unlock()
	if d.browserTransport != nil {
		d.browserTransport.promote(host)
	}
}

func (d *Downloader) pendingShieldChallenges() []shieldChallenge {
	d.shieldMu.Lock()
	defer d.shieldMu.Unlock()
	d.shieldInitLocked()
	out := []shieldChallenge{}
	for host, challenge := range d.shieldChallenges {
		if time.Since(challenge.At) > 30*time.Minute {
			delete(d.shieldChallenges, host)
			continue
		}
		out = append(out, challenge)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].At.After(out[j].At) })
	return out
}

func (d *Downloader) shieldClearanceFor(host string) (shieldClearance, bool) {
	d.shieldMu.Lock()
	defer d.shieldMu.Unlock()
	d.shieldInitLocked()
	entry, ok := d.shieldClearances[shieldNormalizeHost(host)]
	return entry, ok
}

func (d *Downloader) setShieldClearance(host, cookie, ua string) error {
	host = shieldNormalizeHost(host)
	cookie = strings.TrimSpace(cookie)
	if host == "" {
		return errors.New("过盾回填缺少站点域名")
	}
	if !strings.Contains(cookie, "cf_clearance=") {
		return errors.New("过盾回填缺少 cf_clearance")
	}
	if ua == "" {
		ua = shieldUserAgent
	}
	d.shieldMu.Lock()
	d.shieldInitLocked()
	d.shieldClearances[host] = shieldClearance{Cookie: cookie, UA: ua, Updated: time.Now()}
	delete(d.shieldChallenges, host)
	d.persistShieldClearancesLocked()
	d.shieldMu.Unlock()
	if d.browserTransport != nil {
		d.browserTransport.promote(host)
	}
	return nil
}

func (d *Downloader) removeShieldClearance(host string) {
	host = shieldNormalizeHost(host)
	if host == "" {
		return
	}
	d.shieldMu.Lock()
	defer d.shieldMu.Unlock()
	d.shieldInitLocked()
	delete(d.shieldClearances, host)
	d.persistShieldClearancesLocked()
}

func (d *Downloader) applyShieldRequest(request *http.Request) (*http.Request, bool) {
	if request == nil || request.URL == nil {
		return request, false
	}
	entry, ok := d.shieldClearanceFor(request.URL.Hostname())
	if !ok {
		return request, false
	}
	cloned := request.Clone(request.Context())
	cloned.Header = request.Header.Clone()
	if entry.Cookie != "" {
		existing := cloned.Header.Get("Cookie")
		if existing == "" {
			cloned.Header.Set("Cookie", entry.Cookie)
		} else if !strings.Contains(existing, "cf_clearance=") {
			cloned.Header.Set("Cookie", existing+"; "+entry.Cookie)
		}
	}
	if entry.UA != "" {
		cloned.Header.Set("User-Agent", entry.UA)
	}
	return cloned, true
}
