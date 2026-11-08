package core

import (
	"context"
	"testing"
)

func TestHongguoAudioBookCollect(t *testing.T) {
	seen := map[string]bool{}
	items := []Drama{}
	hongguoAudioCollectBooks(map[string]any{
		"tab_item": []any{map[string]any{
			"tab_type": 5,
			"cell_data": []any{map[string]any{
				"book_data": []any{map[string]any{
					"book_id": "7189544077984009277", "book_name": "军神出狱",
					"thumb_url": "https://example.test/cover.jpg", "author": "梭罗果", "serial_count": "2566",
				}},
			}},
		}},
	}, seen, &items)
	if len(items) != 1 {
		t.Fatalf("collect books = %d, want 1", len(items))
	}
	book := items[0]
	if book.Source != sourceHongguoAudio || book.SourceID != "7189544077984009277" || book.Title != "军神出狱" || book.Remark != "共2566章" {
		t.Fatalf("book wrong: %+v", book)
	}
	if book.ID != "hongguo_audio:7189544077984009277" {
		t.Fatalf("book ID %q", book.ID)
	}
}

func TestHongguoAudioInvalidResolve(t *testing.T) {
	d := &Downloader{}
	task := Task{Chapter: Chapter{VideoURL: "hongguo-audio://bad"}}
	if _, err := d.resolveHongguoAudioMedia(context.Background(), task); err == nil {
		t.Fatal("bad audio URL should fail")
	}
}

func TestHongguoAudioContentKey(t *testing.T) {
	if _, err := hongguoContentKey(""); err == nil {
		t.Fatal("empty spade should fail")
	}
}
