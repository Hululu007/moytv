package core

import (
	"errors"
	"testing"
)

func TestProviderRegistrySync(t *testing.T) {
	named := []string{
		sourceHGTV, sourceHongguo, sourceHuangdou, sourceHuangguoAI,
		sourceHuangju, sourceYeguo, sourceDSD, sourceGuipian,
		sourceHanxiaoquan, sourceIkanbot, sourceA123, sourceHuangguoVideo,
		sourceCloudFront,
	}
	registered := map[string]bool{}
	for _, descriptor := range nativeProviderRegistry {
		if registered[descriptor.ID] {
			t.Fatalf("duplicate registry entry %q", descriptor.ID)
		}
		registered[descriptor.ID] = true
		if !isHuangguoProviderSource(descriptor.ID) {
			t.Fatalf("registry entry %q is not an accepted source", descriptor.ID)
		}
	}
	for _, id := range named {
		if !registered[id] {
			t.Fatalf("accepted source %q missing from registry", id)
		}
		if !isHuangguoProviderSource(id) {
			t.Fatalf("named source %q is not accepted", id)
		}
	}
}

func TestProviderSupportsFilters(t *testing.T) {
	if !providerSupportsFilters(sourceHGTV) {
		t.Fatal("HGTV should support filters")
	}
	if !providerSupportsFilters(sourceHongguo) {
		t.Fatal("Hongguo should support filters for book categories")
	}
	for _, id := range []string{
		sourceHuangdou, sourceHuangguoAI, sourceHuangju,
		sourceYeguo, sourceDSD, sourceGuipian, sourceHanxiaoquan,
		sourceIkanbot, sourceA123, sourceHuangguoVideo, sourceCloudFront,
	} {
		if providerSupportsFilters(id) {
			t.Fatalf("source %q should not support filters", id)
		}
	}
	if providerSupportsFilters("no-such-source") {
		t.Fatal("unknown source should not support filters")
	}
	for key := range duanjuSourcesByName {
		if key == sourceHGTV || key == sourceHongguo || key == sourceHuangdou ||
			key == sourceHuangguoAI || key == sourceHuangju || key == sourceYeguo ||
			key == sourceDSD || key == sourceGuipian || key == sourceHanxiaoquan ||
			key == sourceIkanbot || key == sourceA123 || key == sourceHuangguoVideo ||
			key == sourceCloudFront {
			continue
		}
		if providerSupportsFilters(key) {
			t.Fatalf("duanju family source %q should not support filters", key)
		}
		break
	}
	for _, id := range sekuPublicSources() {
		if providerSupportsFilters(id) {
			t.Fatalf("seku family source %q should not support filters", id)
		}
		break
	}
}

func TestShouldUseRetryCache(t *testing.T) {
	retryErr := errors.New("disk full")
	cases := []struct {
		name  string
		err   error
		items int
		want  bool
	}{
		{"retry failed with items", retryErr, 3, true},
		{"retry failed without items", retryErr, 0, false},
		{"retry succeeded with items", nil, 3, false},
		{"retry succeeded without items", nil, 0, false},
	}
	for _, tc := range cases {
		if got := shouldUseRetryCache(tc.err, tc.items); got != tc.want {
			t.Fatalf("%s: got %v, want %v", tc.name, got, tc.want)
		}
	}
}
