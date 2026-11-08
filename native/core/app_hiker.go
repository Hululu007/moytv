package core

import (
	"bytes"
	"strconv"
	"strings"

	"golang.org/x/net/html"
)

func hikerParseSingle(htmlText, rule string) string {
	nodes := hikerSelectChain(htmlText, rule)
	if len(nodes) == 0 {
		return ""
	}
	parts := strings.Split(rule, "&&")
	last := strings.TrimSpace(parts[len(parts)-1])
	switch last {
	case "Text":
		return hikerNodeText(nodes[0])
	case "Html":
		return hikerOuterHTML(nodes[0])
	default:
		if hikerIsAttr(last) {
			if v, ok := hikerAttr(nodes[0], last); ok {
				return v
			}
			return ""
		}
		if hikerIsTag(last) {
			return hikerOuterHTML(nodes[0])
		}
		if v, ok := hikerAttr(nodes[0], last); ok {
			return v
		}
		return hikerNodeText(nodes[0])
	}
}

func hikerIsAttr(s string) bool {
	switch s {
	case "title", "href", "src", "data-original", "realsrc", "alt", "data-src", "value", "content", "id", "class", "name", "data-url", "data-href", "data-title", "data-id":
		return true
	}
	return false
}

func hikerIsTag(s string) bool {
	switch s {
	case "a", "li", "ul", "ol", "div", "span", "p", "img", "h1", "h2", "h3", "h4", "h5", "h6", "body", "html", "table", "tr", "td", "section", "article", "header", "footer", "nav", "main", "em", "strong", "i", "b", "button", "input", "select", "option", "video", "source", "script", "style", "link", "meta", "label", "form":
		return true
	}
	return false
}

func hikerParseArray(htmlText, rule string) []string {
	nodes := hikerSelectChain(htmlText, rule)
	parts := strings.Split(rule, "&&")
	last := ""
	if len(parts) > 0 {
		last = strings.TrimSpace(parts[len(parts)-1])
	}
	out := []string{}
	for _, n := range nodes {
		switch last {
		case "Text":
			out = append(out, hikerNodeText(n))
		case "Html":
			out = append(out, hikerOuterHTML(n))
		default:
			if hikerIsAttr(last) {
				if v, ok := hikerAttr(n, last); ok {
					out = append(out, v)
				} else {
					out = append(out, "")
				}
			} else if hikerIsTag(last) {
				out = append(out, hikerOuterHTML(n))
			} else if v, ok := hikerAttr(n, last); ok {
				out = append(out, v)
			} else {
				out = append(out, hikerOuterHTML(n))
			}
		}
	}
	return out
}

func hikerSelectChain(htmlText, rule string) []*html.Node {
	doc, err := html.Parse(strings.NewReader(htmlText))
	if err != nil {
		return nil
	}
	parts := strings.Split(rule, "&&")
	last := strings.TrimSpace(parts[len(parts)-1])
	selectors := parts
	if last == "Text" || last == "Html" {
		selectors = parts[:len(parts)-1]
	} else if len(parts) > 1 && (hikerIsAttr(last) || !hikerIsTag(last)) && !strings.ContainsAny(last, ".# :[]") {
		selectors = parts[:len(parts)-1]
	}
	current := []*html.Node{doc}
	for _, sel := range selectors {
		sel = strings.TrimSpace(sel)
		if sel == "" {
			continue
		}
		next := []*html.Node{}
		for _, n := range current {
			next = append(next, hikerSelectAll(n, sel)...)
		}
		current = next
		if len(current) == 0 {
			return nil
		}
	}
	return current
}

func hikerAttr(n *html.Node, name string) (string, bool) {
	for _, a := range n.Attr {
		if a.Key == name {
			return a.Val, true
		}
	}
	return "", false
}

func hikerNodeText(n *html.Node) string {
	var b bytes.Buffer
	var walk func(*html.Node)
	walk = func(x *html.Node) {
		if x.Type == html.TextNode {
			b.WriteString(x.Data)
		}
		for c := x.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(n)
	return strings.Join(strings.Fields(b.String()), " ")
}

func hikerOuterHTML(n *html.Node) string {
	var b bytes.Buffer
	_ = html.Render(&b, n)
	return b.String()
}

type hikerAttrCond struct {
	name string
	op   string
	val  string
}

func hikerParseAttrCond(inner string) hikerAttrCond {
	inner = strings.TrimSpace(inner)
	for _, op := range []string{"*=", "^=", "$=", "="} {
		if i := strings.Index(inner, op); i >= 0 {
			val := strings.Trim(strings.TrimSpace(inner[i+len(op):]), `"'`)
			return hikerAttrCond{name: strings.TrimSpace(inner[:i]), op: op, val: val}
		}
	}
	return hikerAttrCond{name: inner}
}

type hikerPositional struct {
	kind  string
	index int
}

func hikerSplitPositional(tok string) (string, []hikerPositional) {
	var positions []hikerPositional
	depth := 0
	out := make([]byte, 0, len(tok))
	i := 0
	for i < len(tok) {
		c := tok[i]
		if c == '[' {
			depth++
			out = append(out, c)
			i++
			continue
		}
		if c == ']' && depth > 0 {
			depth--
			out = append(out, c)
			i++
			continue
		}
		if depth == 0 && c == ':' {
			rest := tok[i:]
			if strings.HasPrefix(rest, ":eq(") {
				end := strings.Index(rest, ")")
				if end >= 0 {
					if idx, err := strconv.Atoi(strings.TrimSpace(rest[4:end])); err == nil {
						positions = append(positions, hikerPositional{kind: "eq", index: idx})
						i += end + 1
						continue
					}
				}
			} else if strings.HasPrefix(rest, ":first") {
				after := rest[len(":first"):]
				if after == "" || after[0] == '.' || after[0] == '#' || after[0] == '[' || after[0] == ':' {
					positions = append(positions, hikerPositional{kind: "first"})
					i += len(":first")
					continue
				}
			} else if strings.HasPrefix(rest, ":last") {
				after := rest[len(":last"):]
				if after == "" || after[0] == '.' || after[0] == '#' || after[0] == '[' || after[0] == ':' {
					positions = append(positions, hikerPositional{kind: "last"})
					i += len(":last")
					continue
				}
			}
		}
		out = append(out, c)
		i++
	}
	return string(out), positions
}

func hikerApplyPositionals(nodes []*html.Node, positions []hikerPositional) []*html.Node {
	for _, p := range positions {
		if len(nodes) == 0 {
			return nodes
		}
		switch p.kind {
		case "first":
			nodes = nodes[:1]
		case "last":
			nodes = nodes[len(nodes)-1:]
		case "eq":
			idx := p.index
			if idx < 0 {
				idx += len(nodes)
			}
			if idx < 0 || idx >= len(nodes) {
				return nil
			}
			nodes = nodes[idx : idx+1]
		}
	}
	return nodes
}

func hikerSelectAll(root *html.Node, selector string) []*html.Node {
	selector = hikerStripPseudo(selector)
	tokens := strings.Fields(selector)
	if len(tokens) == 0 {
		return nil
	}
	current := []*html.Node{root}
	for _, tok := range tokens {
		clean, positions := hikerSplitPositional(tok)
		next := []*html.Node{}
		for _, n := range current {
			var walk func(*html.Node)
			walk = func(x *html.Node) {
				for c := x.FirstChild; c != nil; c = c.NextSibling {
					if hikerMatch(c, clean) {
						next = append(next, c)
					}
					walk(c)
				}
			}
			walk(n)
		}
		current = hikerApplyPositionals(next, positions)
		if len(current) == 0 {
			return nil
		}
	}
	return current
}

func hikerStripPseudo(selector string) string {
	if i := strings.Index(selector, ":contains("); i >= 0 {
		end := strings.Index(selector[i:], ")")
		if end >= 0 {
			selector = selector[:i] + selector[i+end+1:]
		}
	}
	if i := strings.Index(selector, ":not("); i >= 0 {
		depth := 0
		end := -1
		for j := i; j < len(selector); j++ {
			if selector[j] == '(' {
				depth++
			} else if selector[j] == ')' {
				depth--
				if depth == 0 {
					end = j
					break
				}
			}
		}
		if end >= 0 {
			selector = selector[:i] + selector[end+1:]
		}
	}
	selector = strings.ReplaceAll(selector, ":matches", "")
	return strings.TrimSpace(selector)
}

func hikerMatch(n *html.Node, tok string) bool {
	if n.Type != html.ElementNode {
		return false
	}
	contains := ""
	if i := strings.Index(tok, ":contains("); i >= 0 {
		end := strings.Index(tok[i:], ")")
		if end >= 0 {
			contains = tok[i+len(":contains(") : i+end]
			tok = tok[:i]
		}
	}
	tag := ""
	cls := ""
	id := ""
	conds := []hikerAttrCond{}
	rest := tok
	for len(rest) > 0 {
		switch rest[0] {
		case '.':
			end := strings.IndexAny(rest[1:], ".#[")
			if end < 0 {
				cls = rest[1:]
				rest = ""
			} else {
				cls = rest[1 : 1+end]
				rest = rest[1+end:]
			}
		case '#':
			end := strings.IndexAny(rest[1:], ".#[")
			if end < 0 {
				id = rest[1:]
				rest = ""
			} else {
				id = rest[1 : 1+end]
				rest = rest[1+end:]
			}
		case '[':
			end := strings.Index(rest, "]")
			if end < 0 {
				rest = ""
			} else {
				conds = append(conds, hikerParseAttrCond(rest[1:end]))
				rest = rest[end+1:]
			}
		default:
			end := strings.IndexAny(rest, ".#[")
			if end < 0 {
				tag = rest
				rest = ""
			} else {
				tag = rest[:end]
				rest = rest[end:]
			}
		}
	}
	if tag != "" && n.Data != tag {
		return false
	}
	if id != "" {
		v, ok := hikerAttr(n, "id")
		if !ok || v != id {
			return false
		}
	}
	if cls != "" {
		v, ok := hikerAttr(n, "class")
		if !ok {
			return false
		}
		found := false
		for _, c := range strings.Fields(v) {
			if c == cls {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	for _, c := range conds {
		v, ok := hikerAttr(n, c.name)
		if !ok {
			return false
		}
		switch c.op {
		case "=":
			if v != c.val {
				return false
			}
		case "*=":
			if !strings.Contains(v, c.val) {
				return false
			}
		case "^=":
			if !strings.HasPrefix(v, c.val) {
				return false
			}
		case "$=":
			if !strings.HasSuffix(v, c.val) {
				return false
			}
		}
	}
	if contains != "" && !strings.Contains(hikerNodeText(n), contains) {
		return false
	}
	return true
}
