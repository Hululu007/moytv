package core

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"
)

const cencProbeSize = 1 << 16

const cencServeChunk = 1 << 20

type cencBox struct {
	offset     int64
	size       int64
	fourcc     string
	bodyOffset int64
	bodySize   int64
}

type cencSample struct {
	offset int64
	size   int64
	iv     [16]byte
}

type cencPrepared struct {
	total     int64
	moovStart int64
	moovPlain []byte
	samples   []cencSample
	key       [16]byte
}

func cencBoxHeader(buf []byte, offset, end int64) (cencBox, bool) {
	if offset < 0 || offset+8 > end || offset+8 > int64(len(buf)) {
		return cencBox{}, false
	}
	size := int64(binary.BigEndian.Uint32(buf[offset : offset+4]))
	fourcc := string(buf[offset+4 : offset+8])
	header := int64(8)
	if size == 1 {
		if offset+16 > end || offset+16 > int64(len(buf)) {
			return cencBox{}, false
		}
		size = int64(binary.BigEndian.Uint64(buf[offset+8 : offset+16]))
		header = 16
	} else if size == 0 {
		size = end - offset
	}
	if size < header || offset+size > end || offset+size > int64(len(buf)) {
		return cencBox{}, false
	}
	return cencBox{offset: offset, size: size, fourcc: fourcc, bodyOffset: offset + header, bodySize: size - header}, true
}

func cencChildren(buf []byte, start, end int64) []cencBox {
	var boxes []cencBox
	for offset := start; offset+8 <= end; {
		box, ok := cencBoxHeader(buf, offset, end)
		if !ok {
			break
		}
		boxes = append(boxes, box)
		offset += box.size
	}
	return boxes
}

func cencFindChild(buf []byte, parent cencBox, fourcc string) (cencBox, bool) {
	for _, box := range cencChildren(buf, parent.bodyOffset, parent.bodyOffset+parent.bodySize) {
		if box.fourcc == fourcc {
			return box, true
		}
	}
	return cencBox{}, false
}

func cencBoxBody(buf []byte, box cencBox) []byte {
	if box.bodyOffset < 0 || box.bodyOffset+box.bodySize > int64(len(buf)) {
		return nil
	}
	return buf[box.bodyOffset : box.bodyOffset+box.bodySize]
}

func cencU32(body []byte, offset int) (uint32, bool) {
	if offset < 0 || offset+4 > len(body) {
		return 0, false
	}
	return binary.BigEndian.Uint32(body[offset : offset+4]), true
}

func cencU64(body []byte, offset int) (uint64, bool) {
	if offset < 0 || offset+8 > len(body) {
		return 0, false
	}
	return binary.BigEndian.Uint64(body[offset : offset+8]), true
}

func cencParseTrack(moov []byte, trak cencBox, moovStart int64) ([]cencSample, error) {
	mdia, ok := cencFindChild(moov, trak, "mdia")
	if !ok {
		return nil, errors.New("trak 缺少 mdia")
	}
	minf, ok := cencFindChild(moov, mdia, "minf")
	if !ok {
		return nil, errors.New("trak 缺少 minf")
	}
	stbl, ok := cencFindChild(moov, minf, "stbl")
	if !ok {
		return nil, errors.New("trak 缺少 stbl")
	}
	stszBox, ok := cencFindChild(moov, stbl, "stsz")
	if !ok {
		return nil, errors.New("trak 缺少 stsz")
	}
	stscBox, ok := cencFindChild(moov, stbl, "stsc")
	if !ok {
		return nil, errors.New("trak 缺少 stsc")
	}
	saizBox, ok := cencFindChild(moov, stbl, "saiz")
	if !ok {
		return nil, errors.New("trak 缺少 saiz")
	}
	saioBox, ok := cencFindChild(moov, stbl, "saio")
	if !ok {
		return nil, errors.New("trak 缺少 saio")
	}
	stsz := cencBoxBody(moov, stszBox)
	stsc := cencBoxBody(moov, stscBox)
	saiz := cencBoxBody(moov, saizBox)
	saio := cencBoxBody(moov, saioBox)
	if stsz == nil || stsc == nil || saiz == nil || saio == nil {
		return nil, errors.New("trak 样本表越界")
	}
	sampleSize, ok := cencU32(stsz, 4)
	if !ok {
		return nil, errors.New("stsz 过短")
	}
	sampleCount, ok := cencU32(stsz, 8)
	if !ok {
		return nil, errors.New("stsz 过短")
	}
	var sizes []int64
	if sampleSize != 0 {
		for i := uint32(0); i < sampleCount; i++ {
			sizes = append(sizes, int64(sampleSize))
		}
	} else {
		if len(stsz) < 12+int(sampleCount)*4 {
			return nil, errors.New("stsz 样本尺寸表过短")
		}
		for i := uint32(0); i < sampleCount; i++ {
			size, _ := cencU32(stsz, 12+int(i)*4)
			sizes = append(sizes, int64(size))
		}
	}
	var chunkOffsets []int64
	if stcoBox, ok := cencFindChild(moov, stbl, "stco"); ok {
		stco := cencBoxBody(moov, stcoBox)
		if stco == nil {
			return nil, errors.New("stco 越界")
		}
		chunkCount, ok := cencU32(stco, 4)
		if !ok || len(stco) < 8+int(chunkCount)*4 {
			return nil, errors.New("stco 过短")
		}
		for i := uint32(0); i < chunkCount; i++ {
			offset, _ := cencU32(stco, 8+int(i)*4)
			chunkOffsets = append(chunkOffsets, int64(offset))
		}
	} else if co64Box, ok := cencFindChild(moov, stbl, "co64"); ok {
		co64 := cencBoxBody(moov, co64Box)
		if co64 == nil {
			return nil, errors.New("co64 越界")
		}
		chunkCount, ok := cencU32(co64, 4)
		if !ok || len(co64) < 8+int(chunkCount)*8 {
			return nil, errors.New("co64 过短")
		}
		for i := uint32(0); i < chunkCount; i++ {
			offset, _ := cencU64(co64, 8+int(i)*8)
			chunkOffsets = append(chunkOffsets, int64(offset))
		}
	} else {
		return nil, errors.New("trak 缺少 stco/co64")
	}
	entryCount, ok := cencU32(stsc, 4)
	if !ok || len(stsc) < 8+int(entryCount)*12 {
		return nil, errors.New("stsc 过短")
	}
	type stscEntry struct {
		firstChunk      int64
		samplesPerChunk int64
	}
	var entries []stscEntry
	for i := uint32(0); i < entryCount; i++ {
		first, _ := cencU32(stsc, 8+int(i)*12)
		per, _ := cencU32(stsc, 12+int(i)*12)
		if first < 1 {
			return nil, errors.New("stsc 首 chunk 无效")
		}
		entries = append(entries, stscEntry{firstChunk: int64(first), samplesPerChunk: int64(per)})
	}
	chunkSamples := make([]int64, len(chunkOffsets))
	for i, entry := range entries {
		end := int64(len(chunkOffsets))
		if i+1 < len(entries) {
			end = entries[i+1].firstChunk - 1
		}
		for chunk := entry.firstChunk - 1; chunk < end && chunk < int64(len(chunkOffsets)); chunk++ {
			chunkSamples[chunk] = entry.samplesPerChunk
		}
	}
	if len(saiz) < 4 {
		return nil, errors.New("saiz 过短")
	}
	saizFlags := uint32(saiz[1])<<16 | uint32(saiz[2])<<8 | uint32(saiz[3])
	saizCursor := 4
	if saizFlags&1 != 0 {
		saizCursor = 12
	}
	if len(saiz) < saizCursor+5 {
		return nil, errors.New("saiz 过短")
	}
	defaultAuxSize := int64(saiz[saizCursor])
	auxCount, ok := cencU32(saiz, saizCursor+1)
	if !ok {
		return nil, errors.New("saiz 过短")
	}
	var auxSizes []int64
	if defaultAuxSize != 0 {
		for i := uint32(0); i < auxCount; i++ {
			auxSizes = append(auxSizes, defaultAuxSize)
		}
	} else {
		if len(saiz) < saizCursor+5+int(auxCount) {
			return nil, errors.New("saiz 辅助尺寸表过短")
		}
		for i := uint32(0); i < auxCount; i++ {
			auxSizes = append(auxSizes, int64(saiz[saizCursor+5+int(i)]))
		}
	}
	if len(saio) < 4 {
		return nil, errors.New("saio 过短")
	}
	saioFlags := uint32(saio[1])<<16 | uint32(saio[2])<<8 | uint32(saio[3])
	saioCursor := 4
	if saioFlags&1 != 0 {
		saioCursor = 12
	}
	offsetWidth := 4
	if saio[0] == 1 {
		offsetWidth = 8
	}
	if len(saio) < saioCursor+4+offsetWidth {
		return nil, errors.New("saio 过短")
	}
	saioEntries, ok := cencU32(saio, saioCursor)
	if !ok || saioEntries < 1 {
		return nil, errors.New("saio 条目无效")
	}
	var auxOffset int64
	if offsetWidth == 8 {
		value, ok := cencU64(saio, saioCursor+4)
		if !ok {
			return nil, errors.New("saio 过短")
		}
		auxOffset = int64(value)
	} else {
		value, ok := cencU32(saio, saioCursor+4)
		if !ok {
			return nil, errors.New("saio 过短")
		}
		auxOffset = int64(value)
	}
	return cencTrackSamples(moov, moovStart, chunkOffsets, chunkSamples, sizes, auxSizes, auxOffset, int64(sampleCount))
}

func cencTrackSamples(moov []byte, moovStart int64, chunkOffsets, chunkSamples, sizes, auxSizes []int64, auxOffset, sampleCount int64) ([]cencSample, error) {
	var auxLength int64
	for _, size := range auxSizes {
		if size < 8 {
			size = 8
		}
		auxLength += size
	}
	auxLocal := auxOffset - moovStart
	if auxLocal < 0 || auxLocal+auxLength > int64(len(moov)) {
		return nil, errors.New("CENC 辅助信息不在 moov 内，无法流式解密")
	}
	aux := moov[auxLocal : auxLocal+auxLength]
	var samples []cencSample
	var sampleIndex, auxIndex int64
	for chunkIndex, chunkOffset := range chunkOffsets {
		current := chunkOffset
		for n := int64(0); n < chunkSamples[chunkIndex]; n++ {
			if sampleIndex >= sampleCount || sampleIndex >= int64(len(sizes)) {
				break
			}
			if sampleIndex >= int64(len(auxSizes)) {
				return nil, errors.New("CENC 辅助信息数量不足")
			}
			entrySize := auxSizes[sampleIndex]
			if entrySize < 8 {
				entrySize = 8
			}
			take := entrySize
			if take > 8 {
				take = 8
			}
			if auxIndex+take > int64(len(aux)) {
				return nil, errors.New("CENC 辅助信息越界")
			}
			var iv [16]byte
			copy(iv[:take], aux[auxIndex:auxIndex+take])
			samples = append(samples, cencSample{offset: current, size: sizes[sampleIndex], iv: iv})
			current += sizes[sampleIndex]
			auxIndex += entrySize
			sampleIndex++
		}
	}
	return samples, nil
}

func cencSampleTable(moov []byte, moovStart int64) ([]cencSample, error) {
	moovBox, ok := cencBoxHeader(moov, 0, int64(len(moov)))
	if !ok {
		return nil, errors.New("moov 盒无效")
	}
	var samples []cencSample
	for _, trak := range cencChildren(moov, moovBox.bodyOffset, moovBox.bodyOffset+moovBox.bodySize) {
		if trak.fourcc != "trak" {
			continue
		}
		trackSamples, err := cencParseTrack(moov, trak, moovStart)
		if err != nil {
			return nil, err
		}
		samples = append(samples, trackSamples...)
	}
	if len(samples) == 0 {
		return nil, errors.New("moov 中没有可解密的 CENC 样本")
	}
	sort.Slice(samples, func(i, j int) bool { return samples[i].offset < samples[j].offset })
	return samples, nil
}

var cencVideoConfigFormats = [][2]string{
	{"hvcC", "hvc1"}, {"hev1C", "hev1"}, {"av1C", "av01"}, {"vpcC", "vp09"},
	{"avcC", "avc1"}, {"dvvC", "dvh1"}, {"dvhC", "dvh1"},
}

var cencAudioConfigFormats = [][2]string{
	{"esds", "mp4a"}, {"opusC", "Opus"}, {"ac-3", "ac-3"}, {"ec-3", "ec-3"},
}

func cencPrintable(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < 32 || s[i] >= 127 {
			return false
		}
	}
	return true
}

func cencFormatFromConfig(blob []byte, audioFirst bool) string {
	var probes [][2]string
	if audioFirst {
		probes = append(append([][2]string{}, cencAudioConfigFormats...), cencVideoConfigFormats...)
	} else {
		probes = append(append([][2]string{}, cencVideoConfigFormats...), cencAudioConfigFormats...)
	}
	hitPos, hitFmt := -1, ""
	for _, probe := range probes {
		pos := bytes.Index(blob, []byte(probe[0]))
		if pos >= 0 && (hitPos < 0 || pos < hitPos) {
			hitPos, hitFmt = pos, probe[1]
		}
	}
	return hitFmt
}

func cencFormatNear(data []byte, entryPos int, def, kind string) string {
	end := entryPos + 800
	if end > len(data) {
		end = len(data)
	}
	blob := data[entryPos:end]
	idx := 0
	for {
		rel := bytes.Index(blob[idx:], []byte("frma"))
		if rel < 0 {
			break
		}
		pos := idx + rel
		if pos+8 <= len(blob) {
			format := string(blob[pos+4 : pos+8])
			if format != "" && format != "\x00\x00\x00\x00" && format != "encv" && format != "enca" && cencPrintable(format) {
				return format
			}
		}
		idx = pos + 4
	}
	if probed := cencFormatFromConfig(blob, kind == "enca"); probed != "" {
		return probed
	}
	return def
}

func cencRestoreCodecs(data []byte) {
	pos := 0
	for {
		rel := bytes.Index(data[pos:], []byte("encv"))
		if rel < 0 {
			break
		}
		pos += rel
		copy(data[pos:pos+4], cencFormatNear(data, pos, "avc1", "encv"))
		pos += 4
	}
	pos = 0
	for {
		rel := bytes.Index(data[pos:], []byte("enca"))
		if rel < 0 {
			break
		}
		pos += rel
		copy(data[pos:pos+4], cencFormatNear(data, pos, "mp4a", "enca"))
		pos += 4
	}
}

func cencReplaceSinf(data []byte) {
	pos := 0
	for {
		rel := bytes.Index(data[pos:], []byte("sinf"))
		if rel < 0 {
			return
		}
		pos += rel
		if pos >= 4 {
			size := int64(binary.BigEndian.Uint32(data[pos-4 : pos]))
			end := int64(pos) - 4 + size
			var child string
			if pos+12 <= len(data) {
				child = string(data[pos+8 : pos+12])
			}
			if size >= 8 && size < 50000 && end <= int64(len(data)) && (child == "frma" || child == "schm" || child == "schi") {
				copy(data[pos:pos+4], "free")
				for i := pos + 4; i < int(end); i++ {
					data[i] = 0
				}
				pos = int(end)
				continue
			}
		}
		pos += 4
	}
}

func cencPrepare(moov []byte, moovStart, total int64, key []byte) (*cencPrepared, error) {
	if len(key) != 16 {
		return nil, errors.New("CENC 密钥长度错误")
	}
	if total <= 0 || moovStart < 0 || moovStart+int64(len(moov)) > total {
		return nil, errors.New("moov 越界")
	}
	plain := append([]byte{}, moov...)
	cencRestoreCodecs(plain)
	cencReplaceSinf(plain)
	samples, err := cencSampleTable(moov, moovStart)
	if err != nil {
		return nil, err
	}
	var keyArr [16]byte
	copy(keyArr[:], key)
	return &cencPrepared{total: total, moovStart: moovStart, moovPlain: plain, samples: samples, key: keyArr}, nil
}

func cencAddCounter(counter [16]byte, add uint64) [16]byte {
	low := binary.BigEndian.Uint64(counter[8:16])
	high := binary.BigEndian.Uint64(counter[0:8])
	oldLow := low
	low += add
	if low < oldLow {
		high++
	}
	binary.BigEndian.PutUint64(counter[0:8], high)
	binary.BigEndian.PutUint64(counter[8:16], low)
	return counter
}

func (prepared *cencPrepared) patch(buf []byte, base int64) {
	if len(buf) == 0 {
		return
	}
	end := base + int64(len(buf)) - 1
	index := sort.Search(len(prepared.samples), func(i int) bool { return prepared.samples[i].offset > base }) - 1
	if index < 0 {
		index = 0
	}
	block, err := aes.NewCipher(prepared.key[:])
	if err != nil {
		return
	}
	for ; index < len(prepared.samples); index++ {
		sample := prepared.samples[index]
		if sample.offset > end {
			break
		}
		if sample.offset+sample.size <= base {
			continue
		}
		first := sample.offset
		if first < base {
			first = base
		}
		last := sample.offset + sample.size - 1
		if last > end {
			last = end
		}
		skip := first - sample.offset
		counter := cencAddCounter(sample.iv, uint64(skip/16))
		padding := skip % 16
		src := make([]byte, padding+last-first+1)
		copy(src[padding:], buf[first-base:last-base+1])
		dst := make([]byte, len(src))
		cipher.NewCTR(block, counter[:]).XORKeyStream(dst, src)
		copy(buf[first-base:last-base+1], dst[padding:])
	}
	moovEnd := prepared.moovStart + int64(len(prepared.moovPlain))
	if base < moovEnd && end >= prepared.moovStart {
		first := base
		if first < prepared.moovStart {
			first = prepared.moovStart
		}
		last := end
		if last > moovEnd-1 {
			last = moovEnd - 1
		}
		copy(buf[first-base:last-base+1], prepared.moovPlain[first-prepared.moovStart:last-prepared.moovStart+1])
	}
}

func cencParseDigits(s string) (int64, bool) {
	if s == "" {
		return 0, false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
	}
	value, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return math.MaxInt64, true
	}
	return value, true
}

func cencParseRange(value string, total int64) (start, end int64, ranged, unsat bool) {
	text := strings.ToLower(strings.TrimSpace(value))
	if !strings.HasPrefix(text, "bytes=") {
		return 0, 0, false, false
	}
	spec := strings.TrimSpace(strings.SplitN(text[len("bytes="):], ",", 2)[0])
	dash := strings.Index(spec, "-")
	if dash < 0 {
		return 0, 0, false, false
	}
	left, right := spec[:dash], spec[dash+1:]
	if left == "" {
		length, ok := cencParseDigits(right)
		if !ok {
			return 0, 0, false, false
		}
		if length > total {
			length = total
		}
		if length == 0 {
			return 0, 0, false, true
		}
		return total - length, total - 1, true, false
	}
	startValue, ok := cencParseDigits(left)
	if !ok {
		return 0, 0, false, false
	}
	start = startValue
	end = total - 1
	if endValue, ok := cencParseDigits(right); ok {
		end = endValue
	}
	if end > total-1 {
		end = total - 1
	}
	if start >= total || start > end {
		return 0, 0, false, true
	}
	return start, end, true, false
}

type cencRangeFetcher func(ctx context.Context, start, end int64) ([]byte, int64, error)

func cencProbeBoxes(probe []byte) []cencBox {
	var boxes []cencBox
	var offset int64
	for offset+8 <= int64(len(probe)) {
		size := int64(binary.BigEndian.Uint32(probe[offset : offset+4]))
		fourcc := string(probe[offset+4 : offset+8])
		header := int64(8)
		if size == 1 {
			if offset+16 > int64(len(probe)) {
				break
			}
			size = int64(binary.BigEndian.Uint64(probe[offset+8 : offset+16]))
			header = 16
		} else if size == 0 {
			break
		}
		if size < header {
			break
		}
		boxes = append(boxes, cencBox{offset: offset, size: size, fourcc: fourcc, bodyOffset: offset + header, bodySize: size - header})
		offset += size
	}
	return boxes
}

func cencSetup(ctx context.Context, key []byte, fetch cencRangeFetcher) (*cencPrepared, error) {
	if len(key) != 16 {
		return nil, errors.New("CENC 密钥长度错误")
	}
	probe, total, err := fetch(ctx, 0, cencProbeSize-1)
	if err != nil {
		return nil, err
	}
	if total <= 0 {
		return nil, errors.New("媒体总长度未知")
	}
	var moovStart, moovSize int64
	for _, box := range cencProbeBoxes(probe) {
		if box.fourcc == "moov" {
			moovStart, moovSize = box.offset, box.size
			break
		}
	}
	if moovSize == 0 {
		return nil, errors.New("未找到 moov 顶层盒")
	}
	if moovStart+moovSize > total {
		return nil, errors.New("moov 越界")
	}
	var moov []byte
	if moovStart+moovSize <= int64(len(probe)) {
		moov = probe[moovStart : moovStart+moovSize]
	} else {
		fetched, _, err := fetch(ctx, moovStart, moovStart+moovSize-1)
		if err != nil {
			return nil, err
		}
		if int64(len(fetched)) != moovSize {
			return nil, errors.New("moov 分片长度不符")
		}
		moov = fetched
	}
	return cencPrepare(moov, moovStart, total, key)
}

func cencServeRange(ctx context.Context, writer http.ResponseWriter, request *http.Request, prepared *cencPrepared, fetch cencRangeFetcher) {
	total := prepared.total
	if total <= 0 {
		http.Error(writer, "媒体长度未知", http.StatusBadGateway)
		return
	}
	start, end, ranged, unsat := cencParseRange(request.Header.Get("Range"), total)
	if unsat {
		writer.Header().Set("Content-Type", "text/plain; charset=utf-8")
		writer.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", total))
		writer.Header().Set("Content-Length", "0")
		writer.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
		return
	}
	if !ranged {
		start, end = 0, total-1
	}
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("Content-Type", "video/mp4")
	writer.Header().Set("Accept-Ranges", "bytes")
	writer.Header().Set("Content-Length", strconv.FormatInt(end-start+1, 10))
	if ranged {
		writer.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, total))
	}
	if request.Method == http.MethodHead {
		if ranged {
			writer.WriteHeader(http.StatusPartialContent)
		} else {
			writer.WriteHeader(http.StatusOK)
		}
		return
	}
	firstEnd := start + cencServeChunk - 1
	if firstEnd > end {
		firstEnd = end
	}
	first, _, err := fetch(ctx, start, firstEnd)
	if err != nil || len(first) == 0 {
		http.Error(writer, "读取媒体失败，请重试", http.StatusBadGateway)
		return
	}
	if int64(len(first)) > firstEnd-start+1 {
		first = first[:firstEnd-start+1]
	}
	if ranged {
		writer.WriteHeader(http.StatusPartialContent)
	} else {
		writer.WriteHeader(http.StatusOK)
	}
	prepared.patch(first, start)
	if _, err := writer.Write(first); err != nil {
		return
	}
	cursor := start + int64(len(first))
	for cursor <= end {
		stop := cursor + cencServeChunk - 1
		if stop > end {
			stop = end
		}
		block, _, err := fetch(ctx, cursor, stop)
		if err != nil || len(block) == 0 {
			return
		}
		if int64(len(block)) > stop-cursor+1 {
			block = block[:stop-cursor+1]
		}
		prepared.patch(block, cursor)
		if _, err := writer.Write(block); err != nil {
			return
		}
		cursor += int64(len(block))
	}
}

func cencReadRangeResponse(response *http.Response, start, end int64) ([]byte, int64, error) {
	want := end - start + 1
	switch response.StatusCode {
	case http.StatusPartialContent:
		total := int64(-1)
		if contentRange := response.Header.Get("Content-Range"); contentRange != "" {
			if slash := strings.LastIndex(contentRange, "/"); slash >= 0 {
				if value, err := strconv.ParseInt(strings.TrimSpace(contentRange[slash+1:]), 10, 64); err == nil {
					total = value
				}
			}
		}
		body, err := io.ReadAll(io.LimitReader(&nativeIdleTimeoutReader{reader: response.Body, idle: nativeStreamIdleTimeout}, want+1))
		if err != nil {
			return nil, 0, err
		}
		if int64(len(body)) < want {
			return nil, 0, errors.New("媒体分片长度不足")
		}
		return body[:want], total, nil
	case http.StatusOK:
		total := int64(-1)
		if length := response.Header.Get("Content-Length"); length != "" {
			if value, err := strconv.ParseInt(length, 10, 64); err == nil {
				total = value
			}
		}
		if start > 0 {
			if _, err := io.CopyN(io.Discard, &nativeIdleTimeoutReader{reader: response.Body, idle: nativeStreamIdleTimeout}, start); err != nil {
				return nil, 0, err
			}
		}
		body, err := io.ReadAll(io.LimitReader(&nativeIdleTimeoutReader{reader: response.Body, idle: nativeStreamIdleTimeout}, want+1))
		if err != nil {
			return nil, 0, err
		}
		if int64(len(body)) < want {
			return nil, 0, errors.New("媒体分片长度不足")
		}
		if total < 0 {
			total = int64(len(body)) + start
		}
		return body[:want], total, nil
	default:
		return nil, 0, fmt.Errorf("媒体分片请求失败 %d", response.StatusCode)
	}
}

func (stream *nativeStreamServer) nativeFetchRange(ctx context.Context, session *nativeStreamSession, address string, start, end int64) ([]byte, int64, error) {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		fetchAddress := address
		if session.hook != nil {
			signed, err := session.hook.SignSegment(fetchAddress)
			if err != nil {
				return nil, 0, errors.New("播放凭证刷新失败，请重试")
			}
			fetchAddress = signed
		}
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, fetchAddress, nil)
		if err != nil {
			return nil, 0, err
		}
		request.Header.Set("User-Agent", userAgent)
		request.Header.Set("Referer", session.referer)
		request.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, end))
		response, err := stream.nativeRequest(request)
		if err != nil {
			lastErr = err
			continue
		}
		body, total, err := cencReadRangeResponse(response, start, end)
		response.Body.Close()
		if err != nil {
			lastErr = err
			continue
		}
		return body, total, nil
	}
	if lastErr == nil {
		lastErr = errors.New("读取媒体失败，请重试")
	}
	return nil, 0, lastErr
}

func (stream *nativeStreamServer) nativeServeCENC(writer http.ResponseWriter, request *http.Request, session *nativeStreamSession, asset nativeStreamAsset) {
	ctx, cancel := context.WithCancel(providerMediaContext(request.Context(), session.credentials))
	defer cancel()
	stop := context.AfterFunc(session.ctx, cancel)
	defer stop()
	fetch := func(fetchCtx context.Context, start, end int64) ([]byte, int64, error) {
		return stream.nativeFetchRange(fetchCtx, session, asset.address, start, end)
	}
	cencServeRange(ctx, writer, request, asset.cenc, fetch)
}

func (stream *nativeStreamServer) nativeCENCActive(token string) bool {
	stream.mu.Lock()
	session := stream.sessions[token]
	stream.mu.Unlock()
	if session == nil {
		return false
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	for _, asset := range session.assets {
		if asset.cenc != nil {
			return true
		}
	}
	return false
}
