package core

import (
	"testing"
)

func TestLegadoNthChildAndSibling(t *testing.T) {
	body := `<div id="xinxi"><div class="xx"><ul><li>书名X</li><li>别名</li><li><a href="/a">作者Y</a></li><li><a href="/c">最新章Z</a></li></ul></div></div><div id="list"><dl><dt>卷一</dt><dd><a href="/c1">第一章</a></dd><dt>卷二</dt><dd><a href="/c2">第二章</a></dd><dd><a href="/c3">第三章</a></dd></dl></div>`
	ctx := newLegadoJSCtx("http://x.example")
	if got := ctx.evalScalar(body, "#xinxi .xx ul li:nth-child(1)@text"); got != "书名X" {
		t.Fatalf("nth-child(1) wrong: %q", got)
	}
	if got := ctx.evalScalar(body, "#xinxi .xx ul li:nth-child(3) a@text"); got != "作者Y" {
		t.Fatalf("nth-child(3) wrong: %q", got)
	}
	if got := ctx.evalScalar(body, "#xinxi .xx ul li:nth-child(4) a@text"); got != "最新章Z" {
		t.Fatalf("nth-child(4) wrong: %q", got)
	}
	blocks := ctx.evalList(body, "#list dl dt:nth-of-type(2) ~ dd a")
	if len(blocks) != 2 {
		t.Fatalf("sibling list wrong count %d: %v", len(blocks), blocks)
	}
	if got := ctx.evalScalar(blocks[0], "text"); got != "第二章" {
		t.Fatalf("sibling first wrong: %q", got)
	}
	if got := ctx.evalScalar(blocks[1], "href"); got != "/c3" {
		t.Fatalf("sibling second href wrong: %q", got)
	}
}
