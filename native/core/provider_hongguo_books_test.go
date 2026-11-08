package core

import "testing"

func TestHongguoBookCategories(t *testing.T) {
	if len(hongguoBookCategories) != 14 {
		t.Fatalf("book categories = %d, want 14", len(hongguoBookCategories))
	}
	if !hongguoIsBookCategory("novel") || !hongguoIsBookCategory("audio") || !hongguoIsBookCategory("bcat1") || !hongguoIsBookCategory("bcat15") {
		t.Fatal("novel/audio/bcat should be book categories")
	}
	if hongguoIsBookCategory("bcat14") || hongguoIsBookCategory("short_play") {
		t.Fatal("bcat14 is invalid and short_play is not a book category")
	}
	if hongguoBookCategoryName("1") != "都市" {
		t.Fatal("bcat1 name wrong")
	}
}

func TestHongguoBookFromAny(t *testing.T) {
	book := hongguoBookFromAny(map[string]any{
		"book_id": "7189544077984009277", "book_name": "军神出狱",
		"thumb_url": "https://cdn.test/cover.jpg", "serial_count": "2566",
	}, "audio", "听书")
	if book.ID != "hongguo:audio:7189544077984009277" || book.Source != sourceHongguo || book.SourceID != "audio:7189544077984009277" {
		t.Fatalf("book id wrong: %+v", book)
	}
	if book.Remark != "共2566章" {
		t.Fatalf("remark wrong: %s", book.Remark)
	}
	if hongguoBookFromAny(map[string]any{"book_id": "abc"}, "novel", "小说").ID != "" {
		t.Fatal("non-numeric book id should be rejected")
	}
}

func TestHongguoFontDecode(t *testing.T) {
	if len(hongguoFontMap) < 300 {
		t.Fatalf("font map = %d, want at least 300", len(hongguoFontMap))
	}
	if hongguoDecodeFontText(string(rune(58345))) != "在" {
		t.Fatal("font decode wrong")
	}
	if hongguoDecodeFontText("普通") != "普通" {
		t.Fatal("plain text should pass through")
	}
}

func TestHongguoBookmallCellFilter(t *testing.T) {
	seen := map[string]bool{}
	items := []Drama{}
	var categories []nativeFilterOption
	tab := map[string]any{
		"cell_data": []any{
			map[string]any{
				"cell_name": "排行榜", "cell_id": "111",
				"book_data": []any{
					map[string]any{"book_id": "1001", "book_name": "书一", "category": "种田"},
				},
			},
			map[string]any{
				"cell_name": "猜你喜欢", "cell_id": "222",
				"book_data": []any{
					map[string]any{"book_id": "1002", "book_name": "书二", "category": "悬疑灵异"},
				},
			},
		},
	}
	hongguoCollectBookmallCells(tab, "悬疑灵异", "novel", "小说", seen, &items, &categories)
	if len(items) != 1 || items[0].Title != "书二" {
		t.Fatalf("category filter wrong: %+v", items)
	}
	if len(categories) != 2 {
		t.Fatalf("categories = %d, want 2", len(categories))
	}
}

func TestHongguoNovelFilterGroups(t *testing.T) {
	groups := hongguoNovelFilterGroups()
	if len(groups) != 3 || groups[0].Key != "ncat" || groups[0].Name != "二级分类" {
		t.Fatalf("novel filters = %+v", groups)
	}
	if len(groups[0].Options) != 15 {
		t.Fatalf("ncat options = %d, want 15 (全部 + 14 大类)", len(groups[0].Options))
	}
}
