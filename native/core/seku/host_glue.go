package seku

import "strings"

func dramaID(slot, raw string) string { return slot + ":" + raw }

func splitDramaID(source, drama string) (slot, raw string) {
	slot = slotForSource(source)
	raw = strings.TrimSpace(drama)
	if i := strings.Index(raw, ":"); i > 0 {
		if s := slotForSource(raw[:i]); s != "" {
			return s, raw[i+1:]
		}
	}
	return slot, raw
}

func Init(dir string) { setStoreDir(dir) }

func HomeURL(slot string) string { return providerHomeURL(slot) }
