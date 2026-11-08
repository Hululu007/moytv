package core

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestValidateCustomMaccmsInput(t *testing.T) {
	if _, _, _, err := validateCustomMaccmsInput("", "", "", ""); err == nil {
		t.Fatal("empty name and base must fail")
	}
	if _, _, _, err := validateCustomMaccmsInput("test", "ftp://example.com/", "", ""); err == nil {
		t.Fatal("non-http base must fail")
	}
	if _, _, _, err := validateCustomMaccmsInput("test", "https://example.com/?a=1", "", ""); err == nil {
		t.Fatal("base with query must fail")
	}
	if _, _, _, err := validateCustomMaccmsInput("test", "https://localhost/", "", ""); err == nil {
		t.Fatal("host without a dot must fail")
	}
	if _, _, _, err := validateCustomMaccmsInput(strings.Repeat("名", 41), "https://example.com/", "", ""); err == nil {
		t.Fatal("name over 40 runes must fail")
	}
	name, base, kind, err := validateCustomMaccmsInput("test", "https://example.com/", "", "WEB")
	if err != nil || name != "test" || base != "https://example.com" || kind != "web" {
		t.Fatalf("valid input: %q %q %q %v", name, base, kind, err)
	}
	if _, _, _, err := validateCustomMaccmsInput("test", "https://example.com/", "not json", ""); err == nil {
		t.Fatal("unparsable rule must fail")
	}
	if _, _, _, err := validateCustomMaccmsInput("test", "https://example.com/", `{"标题":"x"}`, ""); err == nil {
		t.Fatal("rule without a home url must fail")
	}
	name, base, _, err = validateCustomMaccmsInput("", "", `{"主页url":"https://vip.example.com/"}`, "")
	if err != nil || name != "vip.example.com" || base != "https://vip.example.com" {
		t.Fatalf("rule defaults: %q %q %v", name, base, err)
	}
}

func TestCustomRegistryAddUsesValidation(t *testing.T) {
	registry := &customMaccmsRegistry{
		path:    filepath.Join(t.TempDir(), "custom_sources.json"),
		sources: map[string]customMaccmsSource{},
	}
	record, err := registry.add("test", "https://example.com/", "", "web")
	if err != nil || record.Name != "test" || record.Type != "web" {
		t.Fatalf("add: %+v %v", record, err)
	}
	if _, err := registry.add("other", "https://example.com/", "", ""); err == nil {
		t.Fatal("duplicate base must fail")
	}
	if _, exists := registry.sources[record.ID]; !exists {
		t.Fatal("record must be stored without touching disk")
	}
}
