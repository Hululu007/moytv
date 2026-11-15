package core

import (
	"regexp"
	"strings"
)

// CatVod Node / drpy JS 形态兼容层（解析与调用层，不改 goja 引擎本体）。
//
// 证据来源（只读样本）：
//   - drpy-node 解包样本 spider/catvod/猫测试.js：@header(lang:'cat')、ESM
//     import、home/homeVod/category/detail/play/search 函数名、detail 取单个
//     字符串参数、返回 JSON.stringify 字符串、export default 导出对象、
//     req(url, options).content 取数。
//   - drpy-node 解包样本 spider/js_todo/*.js：var rule = {title, host, url,
//     class_name, 一级, 二级, 搜索, lazy} 声明式规则，无蜘蛛函数。
//   - drpy-node spider/catLib/http.js：req 是同步 http，返回带 content 的
//     响应对象。
//
// 本文件只做三件事：① 把 ESM import/export 语法转成 goja 能跑的形态；
// ② 识别脚本形态（函数蜘蛛 / cat / module.exports / drpy 声明式规则）；
// ③ 给“声明式规则进错引擎”一个能看懂的报错。真正执行 drpy 声明式规则
// 仍需 drpy-node 小程序或 drpyS 服务，本引擎不解释 一级/二级 规则串。

// jsModuleTransformResult 记录 ESM 语法转换的结果。
type jsModuleTransformResult struct {
	script     string
	hadImport  bool
	hadExport  bool
	hadDefault bool
}

// jsStripModuleSyntax 把 ESM import/export 语句转成 goja 可执行的形态：
//   - import ... from '...' / import '...'：整句删掉（assets:// 与相对路径
//     的猫库本引擎没有；脚本若真用到导入的符号，调用时会报 ReferenceError，
//     属于诚实失败；只做 typeof 探测的脚本不受影响）。
//   - export default <expr>; → module.exports = <expr>;（表达式原样保留，
//     查找函数时从 module.exports 里找）。
//   - export function/const/let/var/class → 去掉 export 关键字，声明保留。
//   - export { a, b } [from '...']; / export * from '...'：整句删掉
//     （导出的是已声明的全局符号，引擎按全局名查找）。
//
// 动态 import() 不动。字符串与注释里的 import/export 一律不动；被删掉的
// 语句保留其中的换行，行号不漂移。
func jsStripModuleSyntax(script string) jsModuleTransformResult {
	out := &strings.Builder{}
	out.Grow(len(script))
	hadImport := false
	hadExport := false
	hadDefault := false

	i := 0
	n := len(script)
	// statementStart：上一个有意义的词法单元结束处（文件开头、; 或 } 之后）。
	statementStart := true
	braceDepth := 0
	skipWSAndComments := func(pos int) int {
		for pos < n {
			c := script[pos]
			if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
				pos++
				continue
			}
			if c == '/' && pos+1 < n && script[pos+1] == '/' {
				for pos < n && script[pos] != '\n' {
					pos++
				}
				continue
			}
			if c == '/' && pos+1 < n && script[pos+1] == '*' {
				end := strings.Index(script[pos+2:], "*/")
				if end < 0 {
					return n
				}
				pos += end + 4
				continue
			}
			break
		}
		return pos
	}
	isIdentChar := func(c byte) bool {
		return c == '_' || c == '$' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
	}
	matchKeyword := func(pos int, kw string) bool {
		if pos+len(kw) > n || script[pos:pos+len(kw)] != kw {
			return false
		}
		if pos > 0 && isIdentChar(script[pos-1]) {
			return false
		}
		if pos+len(kw) < n && isIdentChar(script[pos+len(kw)]) {
			return false
		}
		return true
	}
	// skipString：pos 处是引号时跳到字符串结尾之后（处理转义与模板 ${} 嵌套）。
	skipString := func(pos int) int {
		quote := script[pos]
		pos++
		if quote == '`' {
			depth := 0
			for pos < n {
				c := script[pos]
				if c == '\\' {
					pos += 2
					continue
				}
				if c == '$' && pos+1 < n && script[pos+1] == '{' {
					depth++
					pos += 2
					continue
				}
				if c == '}' && depth > 0 {
					depth--
					pos++
					continue
				}
				if c == '`' && depth == 0 {
					return pos + 1
				}
				pos++
			}
			return n
		}
		for pos < n {
			c := script[pos]
			if c == '\\' {
				pos += 2
				continue
			}
			if c == quote {
				return pos + 1
			}
			if c == '\n' {
				return pos
			}
			pos++
		}
		return n
	}
	// skipStatement：从 pos 起跳到一条 import/export 语句的结尾（分号或
	// 深度为 0 的换行），返回结束位置（不含分号后的内容，含分号本身）。
	skipStatement := func(pos int) int {
		depth := 0
		sawString := false
		for pos < n {
			c := script[pos]
			if c == '"' || c == '\'' || c == '`' {
				sawString = true
				pos = skipString(pos)
				continue
			}
			if c == '/' && pos+1 < n && script[pos+1] == '/' {
				for pos < n && script[pos] != '\n' {
					pos++
				}
				continue
			}
			if c == '/' && pos+1 < n && script[pos+1] == '*' {
				end := strings.Index(script[pos+2:], "*/")
				if end < 0 {
					return n
				}
				pos += end + 4
				continue
			}
			switch c {
			case '{', '(', '[':
				depth++
			case '}', ')', ']':
				depth--
			case ';':
				if depth <= 0 {
					return pos + 1
				}
			case '\n':
				if depth <= 0 && sawString {
					return pos
				}
			}
			pos++
		}
		return n
	}
	emitSkipped := func(start, end int) {
		for _, c := range script[start:end] {
			if c == '\n' {
				out.WriteByte('\n')
			}
		}
	}

	for i < n {
		// 先处理字符串与注释：原样搬运，内部关键字不触发转换。
		c := script[i]
		if c == '"' || c == '\'' || c == '`' {
			end := skipString(i)
			out.WriteString(script[i:end])
			i = end
			statementStart = false
			continue
		}
		if c == '/' && i+1 < n && script[i+1] == '/' {
			end := i
			for end < n && script[end] != '\n' {
				end++
			}
			out.WriteString(script[i:end])
			i = end
			continue
		}
		if c == '/' && i+1 < n && script[i+1] == '*' {
			end := strings.Index(script[i+2:], "*/")
			if end < 0 {
				out.WriteString(script[i:])
				break
			}
			end += i + 4
			out.WriteString(script[i:end])
			i = end
			continue
		}
		if braceDepth == 0 && statementStart {
			j := skipWSAndComments(i)
			if j < n && matchKeyword(j, "import") {
				after := skipWSAndComments(j + len("import"))
				// import( 动态导入不动；import.meta 也不动。
				if after < n && script[after] != '(' && script[after] != '.' {
					hadImport = true
					end := skipStatement(j)
					emitSkipped(i, end)
					i = end
					statementStart = true
					continue
				}
			}
			if j < n && matchKeyword(j, "export") {
				after := skipWSAndComments(j + len("export"))
				if after < n {
					rest := script[after:]
					switch {
					case strings.HasPrefix(rest, "default") && (len(rest) == 7 || !isIdentChar(rest[7])):
						hadExport = true
						hadDefault = true
						out.WriteString(script[i:j])
						out.WriteString("module.exports =")
						i = after + len("default")
						statementStart = false
						continue
					case strings.HasPrefix(rest, "function") || strings.HasPrefix(rest, "async function") ||
						strings.HasPrefix(rest, "const") || strings.HasPrefix(rest, "let") ||
						strings.HasPrefix(rest, "var") || strings.HasPrefix(rest, "class"):
						hadExport = true
						out.WriteString(script[i:j])
						i = after
						statementStart = true
						continue
					case strings.HasPrefix(rest, "{") || strings.HasPrefix(rest, "*"):
						hadExport = true
						end := skipStatement(j)
						emitSkipped(i, end)
						i = end
						statementStart = true
						continue
					}
				}
			}
		}
		switch c {
		case '{':
			braceDepth++
			statementStart = true
		case '}':
			braceDepth--
			statementStart = true
		case ';':
			statementStart = true
		case ' ', '\t', '\r', '\n':
		default:
			statementStart = false
		}
		out.WriteByte(c)
		i++
	}
	return jsModuleTransformResult{
		script:     out.String(),
		hadImport:  hadImport,
		hadExport:  hadExport,
		hadDefault: hadDefault,
	}
}

// jsScriptShape 是脚本形态的粗分类，只用于报错文案与测试断言，
// 不决定执行路径（执行只看函数能不能找到）。
type jsScriptShape string

const (
	jsShapeFunctionSpider jsScriptShape = "function" // 全局函数 / rule 对象 / Spider 类
	jsShapeCat            jsScriptShape = "cat"      // CatVod cat 形态：@header + home/category/detail/play
	jsShapeModule         jsScriptShape = "module"   // module.exports / exports.* / export default
	jsShapeDrpyRule       jsScriptShape = "drpyRule" // drpy 声明式 rule 对象，无蜘蛛函数
	jsShapeUnknown        jsScriptShape = "unknown"
)

var jsDrpyRuleTitlePattern = regexp.MustCompile(`(?:title|标题)\s*:\s*['"]([^'"]+)['"]`)

// jsHasSpiderFunction 粗判脚本是否含有任一蜘蛛函数形态（全局函数、对象方法、
// module.exports 成员均算；只看名字出现，不做语义分析）。
func jsHasSpiderFunction(script string) bool {
	for _, name := range []string{
		"homeContent", "categoryContent", "detailContent", "searchContent", "playerContent",
		"homeVod",
	} {
		if strings.Contains(script, name) {
			return true
		}
	}
	// cat 短名只认函数定义形态，避免把含 home 字样的普通文本误判。
	for _, pattern := range []string{
		"function home(", "function home (", "home:", "home :",
		"function category(", "category:", "function detail(", "detail:",
		"function search(", "search:", "function play(", "play:",
	} {
		if strings.Contains(script, pattern) {
			return true
		}
	}
	return false
}

// jsDescribeDrpyRule 识别 drpy 声明式规则：rule 对象 + host/url + 一级/二级/
// 搜索/lazy 任一规则字段，且无蜘蛛函数。返回规则标题（取不到为空）与是否命中。
func jsDescribeDrpyRule(script string) (string, bool) {
	if jsHasSpiderFunction(script) {
		return "", false
	}
	hasRuleObject := strings.Contains(script, "var rule") ||
		strings.Contains(script, "let rule") ||
		strings.Contains(script, "const rule") ||
		strings.Contains(script, "rule = {")
	if !hasRuleObject {
		return "", false
	}
	hasHost := strings.Contains(script, "host") && strings.Contains(script, "url")
	hasRuleField := strings.Contains(script, "一级") || strings.Contains(script, "二级") ||
		strings.Contains(script, "搜索") || strings.Contains(script, "lazy") ||
		strings.Contains(script, "class_name") || strings.Contains(script, "class_parse")
	if !hasHost || !hasRuleField {
		return "", false
	}
	title := ""
	if match := jsDrpyRuleTitlePattern.FindStringSubmatch(script); len(match) == 2 {
		title = match[1]
	}
	return title, true
}

// jsClassifyScript 粗分类脚本形态（只用于报错提示与测试）。
func jsClassifyScript(script string) jsScriptShape {
	if _, ok := jsDescribeDrpyRule(script); ok {
		return jsShapeDrpyRule
	}
	if strings.Contains(script, "lang: 'cat'") || strings.Contains(script, `lang: "cat"`) ||
		strings.Contains(script, "@header") {
		return jsShapeCat
	}
	if strings.Contains(script, "module.exports") || strings.Contains(script, "exports.") ||
		strings.Contains(script, "export default") {
		return jsShapeModule
	}
	if jsHasSpiderFunction(script) {
		return jsShapeFunctionSpider
	}
	return jsShapeUnknown
}

// jsDrpyRuleError 为声明式规则生成能看懂的报错（标题/站址有则带上）。
func jsDrpyRuleError(script string, cause error) error {
	title, _ := jsDescribeDrpyRule(script)
	name := "该文件"
	if title != "" {
		name = "规则「" + title + "」"
	}
	return &jsDrpyRuleFailure{name: name, cause: cause}
}

type jsDrpyRuleFailure struct {
	name  string
	cause error
}

func (e *jsDrpyRuleFailure) Error() string {
	return e.name + "是 drpy 声明式规则（rule 对象 + 一级/二级规则串），当前 JS 引擎只执行函数形态蜘蛛，无法直接运行；请改走 drpy-node 小程序或 drpyS 服务"
}

func (e *jsDrpyRuleFailure) Unwrap() error { return e.cause }
