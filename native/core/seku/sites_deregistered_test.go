package seku

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDeregisteredSlotsStayUnregistered(t *testing.T) {
	slots := []string{"pektino", "z2_thdh", "yh_slf", "yh_iqiyi", "yh_nana", "yh_tomato", "yh_bili2tx"}
	for _, slot := range slots {
		if implForSlot(slot) != nil {
			t.Fatalf("slot %s must stay unregistered", slot)
		}
		if _, ok := keyToSlot[slot]; ok {
			t.Fatalf("key %s must not resolve to a slot", slot)
		}
		for _, s := range allSlots() {
			if s == slot {
				t.Fatalf("%s must not appear in allSlots", slot)
			}
		}
	}
}

func TestHsckCatalogFallsBackToMirror(t *testing.T) {
	primary := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer primary.Close()
	mirror := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`<a href="/view/?id=abc123" title="mirror title" data-original="https://cdn.test/cover.jpg"></a> totalPages: 2`))
	}))
	defer mirror.Close()
	old := hsckHosts
	hsckHosts = []string{primary.URL, mirror.URL}
	defer func() { hsckHosts = old }()
	items, total, hasMore, err := hsckCatalog("a123", "new", 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || total != 80 || !hasMore {
		t.Fatalf("mirror catalog wrong: n=%d total=%d more=%v", len(items), total, hasMore)
	}
	item, _ := items[0].(map[string]interface{})
	title, _ := item["title"].(string)
	if !strings.Contains(title, "mirror title") {
		t.Fatalf("mirror item wrong: %+v", item)
	}
}
