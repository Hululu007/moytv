package core

import (
	"testing"

	"moyi/native/core/seku"
)

// v56：seku 内部槽名与短剧自有源撞名（hongguo / ikanbot / a123 /
// hanxiaoquan / guipian / huangdou / huangju / yeguo 共 8 个）。
// 症状是列表能出、一点播放就「站源无效」—— missav 全站播不了就是这条。
// 这几条锁死修复口径，别再改回把槽名当站点 id 输出。

func TestSekuPublicIDsRouteBackToSlots(t *testing.T) {
	broken := 0
	for slot, publicID := range sekuSlotPublicIDs {
		if !seku.HasSlot(slot) {
			continue
		}
		got, ok := sekuSlotForSource(publicID)
		if !ok || got != slot {
			t.Errorf("public id %q does not route to slot %q (got %q, ok=%v)", publicID, slot, got, ok)
			broken++
		}
	}
	if broken > 0 {
		t.Fatalf("%d public ids unroutable", broken)
	}
}

func TestAliasedSlotsStillRefuseRawNames(t *testing.T) {
	// 裸槽名必须继续被拒：短剧自有源（红果）用的就是 hongguo，
	// seku 不能把它抢过来，否则红果短剧整条链路会被路由错。
	for _, raw := range []string{"hongguo", "huangdou", "yeguo", "ikanbot"} {
		if _, ok := sekuSlotForSource(raw); ok {
			t.Errorf("raw slot name %q must NOT be routed to seku", raw)
		}
	}
}

func TestMigrateSekuAliasFixesCachedItems(t *testing.T) {
	cases := []struct {
		source, id, want string
		ok               bool
	}{
		{"hongguo", "hongguo:https://missav.ws/cn/sdam-185", "v_missav", true},
		{"huangdou", "huangdou:https://x/y", "v_whos", true},
		// 短剧自有源：id 是纯数字，绝不能动
		{"hongguo", "hongguo:7189544077984009277", "", false},
		// 已经是对外 id 的不重复迁移
		{"v_missav", "v_missav:https://missav.ws/cn/x", "", false},
		// 非 seku 源
		{"huangguoai", "huangguoai:123", "", false},
	}
	for _, c := range cases {
		got, ok := migrateSekuSourceAlias(c.source, c.id)
		if ok != c.ok || got != c.want {
			t.Errorf("migrateSekuSourceAlias(%q, %q) = (%q, %v), want (%q, %v)",
				c.source, c.id, got, ok, c.want, c.ok)
		}
	}
}

func TestMigrateNativeDramaRewritesIDPrefix(t *testing.T) {
	in := nativeDrama{ID: "hongguo:https://missav.ws/cn/sdam-185", Source: "hongguo", SourceID: "https://missav.ws/cn/sdam-185"}
	out := migrateNativeDrama(in)
	if out.Source != "v_missav" {
		t.Fatalf("source not migrated: %q", out.Source)
	}
	if out.ID != "v_missav:https://missav.ws/cn/sdam-185" {
		t.Fatalf("id prefix not migrated: %q", out.ID)
	}
	if _, _, valid := splitProviderDramaID(out.ID); !valid {
		t.Fatalf("migrated id no longer splits: %q", out.ID)
	}
}
