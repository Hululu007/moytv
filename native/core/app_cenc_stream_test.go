package core

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/binary"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

func cencTestBox(fourcc string, body []byte) []byte {
	out := make([]byte, 8+len(body))
	binary.BigEndian.PutUint32(out[0:4], uint32(8+len(body)))
	copy(out[4:8], fourcc)
	copy(out[8:], body)
	return out
}

func cencTestFullBox(fourcc string, body []byte) []byte {
	full := make([]byte, 4+len(body))
	copy(full[4:], body)
	return cencTestBox(fourcc, full)
}

func cencTestU32(value uint32) []byte {
	out := make([]byte, 4)
	binary.BigEndian.PutUint32(out, value)
	return out
}

type cencTestFile struct {
	file         []byte
	moov         []byte
	moovStart    int64
	total        int64
	key          []byte
	plains       [][]byte
	chunkOffsets []int64
	ivs          [][]byte
	mdatHeader   []byte
}

func buildCENCTestFile(t *testing.T, moovFree, prefixFree int64) cencTestFile {
	t.Helper()
	key := []byte{0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f}
	ivs := [][]byte{
		{0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17},
		{0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27},
		{0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37},
	}
	plains := [][]byte{
		bytes.Repeat([]byte{0x11}, 100),
		bytes.Repeat([]byte{0x22}, 200),
		bytes.Repeat([]byte{0x33}, 150),
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	var encrypted []byte
	for i, plain := range plains {
		var iv [16]byte
		copy(iv[:8], ivs[i])
		out := make([]byte, len(plain))
		cipher.NewCTR(block, iv[:]).XORKeyStream(out, plain)
		encrypted = append(encrypted, out...)
	}

	ftyp := cencTestBox("ftyp", []byte("isom\x00\x00\x00\x00isomiso2"))
	var prefix []byte
	if prefixFree > 0 {
		prefix = cencTestBox("free", make([]byte, prefixFree-8))
	}
	moovStart := int64(len(ftyp) + len(prefix))

	mvhd := cencTestFullBox("mvhd", make([]byte, 100))
	tkhd := cencTestFullBox("tkhd", make([]byte, 92))
	mdhd := cencTestFullBox("mdhd", make([]byte, 32))

	frma := cencTestBox("frma", []byte("avc1"))
	schm := cencTestBox("schm", []byte("cenc\x00\x00\x00\x00"))
	schi := cencTestBox("schi", make([]byte, 4))
	sinf := cencTestBox("sinf", append(append(frma, schm...), schi...))
	avcC := cencTestBox("avcC", make([]byte, 8))
	entryBody := append(append(append(make([]byte, 6), 0, 1), make([]byte, 16)...), sinf...)
	entryBody = append(entryBody, avcC...)
	stsd := cencTestFullBox("stsd", append(cencTestU32(1), cencTestBox("encv", entryBody)...))
	stscBody := append(cencTestU32(1), append(append(cencTestU32(1), cencTestU32(2)...), cencTestU32(1)...)...)
	stsc := cencTestFullBox("stsc", stscBody)
	stszBody := append(append(cencTestU32(0), cencTestU32(3)...), append(append(cencTestU32(100), cencTestU32(200)...), cencTestU32(150)...)...)
	stsz := cencTestFullBox("stsz", stszBody)

	moovFreeBox := int64(0)
	if moovFree > 0 {
		moovFreeBox = moovFree
	}
	stblFixed := int64(len(stsd) + len(stsc) + len(stsz) + 24 + 20 + 20 + 40)
	stblSize := 8 + stblFixed
	minfSize := 8 + stblSize
	mdiaSize := 8 + int64(len(mdhd)) + minfSize
	trakSize := 8 + int64(len(tkhd)) + mdiaSize
	moovSize := 8 + moovFreeBox + int64(len(mvhd)) + trakSize
	moovEnd := moovStart + moovSize
	sampleStart := moovEnd + 8
	chunkOffsets := []int64{sampleStart, sampleStart + 300}

	stcoBody := append(append(cencTestU32(2), cencTestU32(uint32(chunkOffsets[0]))...), cencTestU32(uint32(chunkOffsets[1]))...)
	stco := cencTestFullBox("stco", stcoBody)
	saizBody := append(append([]byte{8}, cencTestU32(3)...), 8, 8, 8)
	saiz := cencTestFullBox("saiz", saizBody)
	saioPlaceholder := cencTestFullBox("saio", append(cencTestU32(1), cencTestU32(0)...))
	sencIVStart := moovStart + 8 + moovFreeBox + int64(len(mvhd)) + 8 + int64(len(tkhd)) + 8 + int64(len(mdhd)) + 8 + 8 + int64(len(stsd)+len(stsc)+len(stsz)+len(stco)+len(saiz)+len(saioPlaceholder)) + 16
	saioBody := append(cencTestU32(1), cencTestU32(uint32(sencIVStart))...)
	saio := cencTestFullBox("saio", saioBody)
	var sencBody []byte
	sencBody = append(sencBody, cencTestU32(3)...)
	for _, iv := range ivs {
		sencBody = append(sencBody, iv...)
	}
	senc := cencTestFullBox("senc", sencBody)

	stblBody := append(append(append(append(append(append(stsd, stsc...), stsz...), stco...), saiz...), saio...), senc...)
	stbl := cencTestBox("stbl", stblBody)
	minf := cencTestBox("minf", stbl)
	mdia := cencTestBox("mdia", append(mdhd, minf...))
	trak := cencTestBox("trak", append(tkhd, mdia...))
	moovBody := append(mvhd, trak...)
	if moovFree > 0 {
		moovBody = append(cencTestBox("free", make([]byte, moovFree-8)), moovBody...)
	}
	moov := cencTestBox("moov", moovBody)
	if int64(len(moov)) != moovSize {
		t.Fatalf("moov 尺寸算错：得到 %d，想要 %d", len(moov), moovSize)
	}
	mdatHeader := make([]byte, 8)
	binary.BigEndian.PutUint32(mdatHeader[0:4], uint32(8+len(encrypted)))
	copy(mdatHeader[4:8], "mdat")
	file := append(append(append(ftyp, prefix...), moov...), mdatHeader...)
	file = append(file, encrypted...)
	return cencTestFile{
		file: file, moov: moov, moovStart: moovStart, total: int64(len(file)),
		key: key, plains: plains, chunkOffsets: chunkOffsets, ivs: ivs, mdatHeader: mdatHeader,
	}
}

func cencTestFetcher(file []byte) cencRangeFetcher {
	return func(ctx context.Context, start, end int64) ([]byte, int64, error) {
		if start < 0 || start >= int64(len(file)) {
			return nil, 0, errors.New("越界")
		}
		if end >= int64(len(file)) {
			end = int64(len(file)) - 1
		}
		if start > end {
			return nil, 0, errors.New("越界")
		}
		return append([]byte{}, file[start:end+1]...), int64(len(file)), nil
	}
}

func TestCENCPrepareAndPatch(t *testing.T) {
	f := buildCENCTestFile(t, 0, 0)
	prepared, err := cencPrepare(f.moov, f.moovStart, f.total, f.key)
	if err != nil {
		t.Fatal(err)
	}
	if len(prepared.samples) != 3 {
		t.Fatalf("样本数 = %d，想要 3", len(prepared.samples))
	}
	wantOffsets := []int64{f.chunkOffsets[0], f.chunkOffsets[0] + 100, f.chunkOffsets[1]}
	wantSizes := []int64{100, 200, 150}
	for i, sample := range prepared.samples {
		if sample.offset != wantOffsets[i] || sample.size != wantSizes[i] {
			t.Fatalf("样本 %d：得到 offset=%d size=%d，想要 offset=%d size=%d", i, sample.offset, sample.size, wantOffsets[i], wantSizes[i])
		}
		var wantIV [16]byte
		copy(wantIV[:8], f.ivs[i])
		if sample.iv != wantIV {
			t.Fatalf("样本 %d IV 不符", i)
		}
	}
	if len(prepared.moovPlain) != len(f.moov) {
		t.Fatalf("改写后 moov 长度变了：%d -> %d", len(f.moov), len(prepared.moovPlain))
	}
	if !bytes.Contains(prepared.moovPlain, []byte("avc1")) {
		t.Fatal("改写后 moov 缺 avc1")
	}
	if bytes.Contains(prepared.moovPlain, []byte("encv")) {
		t.Fatal("改写后 moov 仍有 encv")
	}
	if bytes.Contains(prepared.moovPlain, []byte("sinf")) {
		t.Fatal("改写后 moov 仍有 sinf")
	}
	if !bytes.Contains(prepared.moovPlain, []byte("free")) {
		t.Fatal("改写后 moov 缺 free（sinf 未中和）")
	}

	plainSamples := append(append([]byte{}, f.plains[0]...), f.plains[1]...)
	plainSamples = append(plainSamples, f.plains[2]...)
	wantFull := append(append(append([]byte{}, f.file[:f.moovStart]...), prepared.moovPlain...), f.mdatHeader...)
	wantFull = append(wantFull, plainSamples...)
	full := append([]byte{}, f.file...)
	prepared.patch(full, 0)
	if !bytes.Equal(full, wantFull) {
		t.Fatal("整文件解密结果与预期明文不一致")
	}

	base := f.chunkOffsets[0] + 103
	slice := append([]byte{}, f.file[base:base+50]...)
	prepared.patch(slice, base)
	if !bytes.Equal(slice, f.plains[1][3:53]) {
		t.Fatal("样本内非对齐 Range 解密结果不对")
	}

	moovEnd := f.moovStart + int64(len(f.moov))
	edgeBase := moovEnd - 10
	edge := append([]byte{}, f.file[edgeBase:edgeBase+30]...)
	prepared.patch(edge, edgeBase)
	wantEdge := append(append([]byte{}, prepared.moovPlain[len(prepared.moovPlain)-10:]...), f.mdatHeader...)
	wantEdge = append(wantEdge, f.plains[0][:12]...)
	if !bytes.Equal(edge, wantEdge) {
		t.Fatal("moov 边界处解密结果不对")
	}
}

func TestCENCParseRange(t *testing.T) {
	total := int64(1058)
	cases := []struct {
		value         string
		start, end    int64
		ranged, unsat bool
	}{
		{"", 0, 0, false, false},
		{"bytes=0-99", 0, 99, true, false},
		{"bytes=100-", 100, total - 1, true, false},
		{"bytes=-50", total - 50, total - 1, true, false},
		{"bytes=0-999999", 0, total - 1, true, false},
		{"bytes=999999-", 0, 0, false, true},
		{"bytes=50-40", 0, 0, false, true},
		{"bytes=abc-def", 0, 0, false, false},
		{"bytes=10-20,30-40", 10, 20, true, false},
		{"BYTES=5-9", 5, 9, true, false},
		{"bytes=10-abc", 10, total - 1, true, false},
		{"bytes=-0", 0, 0, false, true},
	}
	for _, c := range cases {
		start, end, ranged, unsat := cencParseRange(c.value, total)
		if start != c.start || end != c.end || ranged != c.ranged || unsat != c.unsat {
			t.Fatalf("Range %q：得到 (%d,%d,%v,%v)，想要 (%d,%d,%v,%v)", c.value, start, end, ranged, unsat, c.start, c.end, c.ranged, c.unsat)
		}
	}
}

func TestCENCServeRange(t *testing.T) {
	f := buildCENCTestFile(t, 0, 0)
	prepared, err := cencPrepare(f.moov, f.moovStart, f.total, f.key)
	if err != nil {
		t.Fatal(err)
	}
	fetch := cencTestFetcher(f.file)
	plainSamples := append(append([]byte{}, f.plains[0]...), f.plains[1]...)
	plainSamples = append(plainSamples, f.plains[2]...)
	wantFull := append(append(append([]byte{}, f.file[:f.moovStart]...), prepared.moovPlain...), f.mdatHeader...)
	wantFull = append(wantFull, plainSamples...)

	serve := func(method, rangeHeader string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(method, "http://127.0.0.1/token/id.mp4", nil)
		if rangeHeader != "" {
			request.Header.Set("Range", rangeHeader)
		}
		recorder := httptest.NewRecorder()
		cencServeRange(context.Background(), recorder, request, prepared, fetch)
		return recorder
	}

	recorder := serve(http.MethodGet, "")
	if recorder.Code != http.StatusOK {
		t.Fatalf("无 Range：状态 = %d，想要 200", recorder.Code)
	}
	if recorder.Header().Get("Content-Length") != fmt.Sprint(f.total) {
		t.Fatalf("无 Range：Content-Length = %s，想要 %d", recorder.Header().Get("Content-Length"), f.total)
	}
	if !bytes.Equal(recorder.Body.Bytes(), wantFull) {
		t.Fatal("无 Range：正文不是解密后全文件")
	}

	sample2Start := f.chunkOffsets[0] + 100
	sample2End := sample2Start + 199
	recorder = serve(http.MethodGet, fmt.Sprintf("bytes=%d-%d", sample2Start, sample2End))
	if recorder.Code != http.StatusPartialContent {
		t.Fatalf("分段：状态 = %d，想要 206", recorder.Code)
	}
	if recorder.Header().Get("Content-Range") != fmt.Sprintf("bytes %d-%d/%d", sample2Start, sample2End, f.total) {
		t.Fatalf("分段：Content-Range = %s", recorder.Header().Get("Content-Range"))
	}
	if !bytes.Equal(recorder.Body.Bytes(), f.plains[1]) {
		t.Fatal("分段：正文不是样本 2 明文")
	}

	recorder = serve(http.MethodGet, "bytes=-50")
	if recorder.Code != http.StatusPartialContent || !bytes.Equal(recorder.Body.Bytes(), wantFull[len(wantFull)-50:]) {
		t.Fatal("后缀 Range 结果不对")
	}

	recorder = serve(http.MethodGet, "bytes=999999-")
	if recorder.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("越界 Range：状态 = %d，想要 416", recorder.Code)
	}
	if recorder.Header().Get("Content-Range") != fmt.Sprintf("bytes */%d", f.total) {
		t.Fatalf("越界 Range：Content-Range = %s", recorder.Header().Get("Content-Range"))
	}

	recorder = serve(http.MethodHead, "")
	if recorder.Code != http.StatusOK || recorder.Body.Len() != 0 || recorder.Header().Get("Content-Length") != fmt.Sprint(f.total) {
		t.Fatal("HEAD 结果不对")
	}
	recorder = serve(http.MethodHead, "bytes=0-99")
	if recorder.Code != http.StatusPartialContent || recorder.Body.Len() != 0 {
		t.Fatal("HEAD + Range 结果不对")
	}

	failFetch := func(ctx context.Context, start, end int64) ([]byte, int64, error) {
		return nil, 0, errors.New("上游断开")
	}
	request := httptest.NewRequest(http.MethodGet, "http://127.0.0.1/token/id.mp4", nil)
	recorder = httptest.NewRecorder()
	cencServeRange(context.Background(), recorder, request, prepared, failFetch)
	if recorder.Code != http.StatusBadGateway {
		t.Fatalf("首块失败：状态 = %d，想要 502", recorder.Code)
	}
}

func TestCENCSetup(t *testing.T) {
	f := buildCENCTestFile(t, 0, 0)
	prepared, err := cencSetup(context.Background(), f.key, cencTestFetcher(f.file))
	if err != nil {
		t.Fatal(err)
	}
	if prepared.total != f.total || len(prepared.samples) != 3 {
		t.Fatalf("建会话：total=%d 样本=%d", prepared.total, len(prepared.samples))
	}

	big := buildCENCTestFile(t, 70000, 0)
	prepared, err = cencSetup(context.Background(), big.key, cencTestFetcher(big.file))
	if err != nil {
		t.Fatalf("moov 超出探针时应二次取 moov，得到错误：%v", err)
	}
	if prepared.total != big.total || len(prepared.samples) != 3 {
		t.Fatalf("moov 超出探针：total=%d 样本=%d", prepared.total, len(prepared.samples))
	}

	shifted := buildCENCTestFile(t, 0, 70000)
	if _, err := cencSetup(context.Background(), shifted.key, cencTestFetcher(shifted.file)); err == nil {
		t.Fatal("moov 不在探针内时应失败")
	}

	bare := cencTestBox("moov", cencTestFullBox("mvhd", make([]byte, 100)))
	bareFile := append(cencTestBox("ftyp", []byte("isom\x00\x00\x00\x00isomiso2")), bare...)
	if _, err := cencSetup(context.Background(), f.key, cencTestFetcher(bareFile)); err == nil {
		t.Fatal("无 CENC 样本的 moov 应失败")
	}
}

func TestNativeCENCActive(t *testing.T) {
	stream := &nativeStreamServer{sessions: map[string]*nativeStreamSession{}}
	withCENC := &nativeStreamSession{assets: map[string]nativeStreamAsset{
		"a.mp4": {address: "https://example.com/a.mp4", contentType: "video/mp4", cenc: &cencPrepared{}},
	}}
	withoutCENC := &nativeStreamSession{assets: map[string]nativeStreamAsset{
		"b.mp4": {address: "https://example.com/b.mp4", contentType: "video/mp4"},
	}}
	stream.sessions["with"] = withCENC
	stream.sessions["without"] = withoutCENC
	if !stream.nativeCENCActive("with") {
		t.Fatal("带 CENC 的会话应返回 true")
	}
	if stream.nativeCENCActive("without") {
		t.Fatal("不带 CENC 的会话应返回 false")
	}
	if stream.nativeCENCActive("missing") {
		t.Fatal("不存在的会话应返回 false")
	}
}
