package core

import (
	"crypto/md5"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"math"
	"net/url"
	"strings"
)

func sixGodVarint(v uint64) []byte {
	var out []byte
	for v > 127 {
		out = append(out, byte(v&127)|128)
		v >>= 7
	}
	return append(out, byte(v))
}

func sixGodSint(v int64) uint64 {
	return uint64((v << 1) ^ (v >> 63))
}

func sixGodPackFloat32(v float64) []byte {
	if v == 0 {
		return []byte{0, 0, 0, 0}
	}
	out := make([]byte, 4)
	binary.LittleEndian.PutUint32(out, math.Float32bits(float32(v)))
	return out
}

type sixGodProtoBuilder struct {
	out []byte
}

func (b *sixGodProtoBuilder) sint(field int, value int64) {
	if value == 0 {
		return
	}
	b.out = append(b.out, sixGodVarint(uint64(field<<3))...)
	b.out = append(b.out, sixGodVarint(sixGodSint(value))...)
}

func (b *sixGodProtoBuilder) float(field int, value float64) {
	if value == 0 {
		return
	}
	b.out = append(b.out, sixGodVarint(uint64(field<<3|5))...)
	b.out = append(b.out, sixGodPackFloat32(value)...)
}

func (b *sixGodProtoBuilder) bytes(field int, value []byte) {
	if len(value) == 0 {
		return
	}
	b.out = append(b.out, sixGodVarint(uint64(field<<3|2))...)
	b.out = append(b.out, sixGodVarint(uint64(len(value)))...)
	b.out = append(b.out, value...)
}

func (b *sixGodProtoBuilder) str(field int, value string) {
	if value == "" {
		return
	}
	b.bytes(field, []byte(value))
}

func (b *sixGodProtoBuilder) msg(field int, value []byte) {
	b.bytes(field, value)
}

func sixGodBytes2Matrix(text []byte) [][]byte {
	var out [][]byte
	for i := 0; i < len(text); i += 4 {
		end := i + 4
		if end > len(text) {
			end = len(text)
		}
		row := make([]byte, end-i)
		copy(row, text[i:end])
		out = append(out, row)
	}
	return out
}

func sixGodXorBytes(a, b []byte) []byte {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	out := make([]byte, n)
	for i := 0; i < n; i++ {
		out[i] = a[i] ^ b[i]
	}
	return out
}

type sixGodAESState [4][4]byte

func sixGodBytes2State(text []byte) sixGodAESState {
	var s sixGodAESState
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			idx := i*4 + j
			if idx < len(text) {
				s[i][j] = text[idx]
			}
		}
	}
	return s
}

func sixGodState2Bytes(s sixGodAESState) []byte {
	out := make([]byte, 0, 16)
	for i := 0; i < 4; i++ {
		out = append(out, s[i][:]...)
	}
	return out
}

func sixGodXtime(a byte) byte {
	if a&128 != 0 {
		return byte(((int(a) << 1) ^ 0x1b) & 255)
	}
	return byte((int(a) << 1) & 255)
}

func sixGodAddRoundKey(s sixGodAESState, k [][]byte) sixGodAESState {
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			s[i][j] ^= k[i][j]
		}
	}
	return s
}

func sixGodAddRoundKeyCon(s sixGodAESState, k [][]byte, con [4]int) sixGodAESState {
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			s[i][j] ^= k[i][con[j]]
		}
	}
	return s
}

func sixGodMixSingleColumn(s *sixGodAESState, col int) {
	t := s[0][col] ^ s[1][col] ^ s[2][col] ^ s[3][col]
	u := s[0][col]
	s[0][col] ^= t ^ sixGodXtime(s[0][col]^s[1][col])
	s[1][col] ^= t ^ sixGodXtime(s[1][col]^s[2][col])
	s[2][col] ^= t ^ sixGodXtime(s[2][col]^s[3][col])
	s[3][col] ^= t ^ sixGodXtime(s[3][col]^u)
}

func sixGodMatrixMixColumns(s sixGodAESState) sixGodAESState {
	for col := 0; col < 4; col++ {
		sixGodMixSingleColumn(&s, col)
	}
	return s
}

type sixGodAESV3 struct {
	wordSize    int
	sBox        []byte
	con         [4]int
	con2        [4]int
	order       [16]int
	masterKey   []byte
	keyMatrices [][]byte
}

func sixGodNewAESV3(aesKey []byte, khronos uint32) (*sixGodAESV3, error) {
	if err := sixGodTables(); err != nil {
		return nil, err
	}
	a := &sixGodAESV3{wordSize: int(khronos & 3)}
	a.sBox = sixGodSBox[a.wordSize*256:]
	rCon := [4][4]int{{1, 0, 2, 3}, {1, 3, 0, 2}, {0, 1, 3, 2}, {1, 0, 2, 3}}
	rCon2 := [4][4]int{{1, 0, 2, 3}, {2, 0, 3, 1}, {0, 1, 3, 2}, {1, 0, 2, 3}}
	rOrders := [4][16]int{
		{0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3},
		{0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11},
		{0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15},
		{0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3},
	}
	a.con = rCon[a.wordSize]
	a.con2 = rCon2[a.wordSize]
	a.order = rOrders[a.wordSize]
	a.masterKey = a.expandKey(aesKey)
	a.keyMatrices = sixGodBytes2Matrix(a.masterKey)
	return a, nil
}

func (a *sixGodAESV3) expandKey(aesKey []byte) []byte {
	initValues := [4]uint32{0xca025ddc, 0x823dc546, 0xc9420583, 0xc298225f}
	initValue := initValues[a.wordSize]
	mk := make([]byte, 0, 48)
	for i := 0; i < 4; i++ {
		mk = append(mk, byte(initValue), byte(initValue>>8), byte(initValue>>16), byte(initValue>>24))
	}
	mk = sixGodXorBytes(mk, aesKey)
	for i := 0; i < 32; i++ {
		mk = append(mk, 0)
	}
	rounds := 8
	for i := 4; i < 12; i++ {
		idx := 4 * (i - 1)
		k0, k1, k2, k3 := mk[idx], mk[idx+1], mk[idx+2], mk[idx+3]
		if i&3 == 0 {
			k00 := uint32((int32(initValue) >> uint(rounds&24)) ^ int32(a.sBox[k1]))
			k1 = a.sBox[k2]
			k2 = a.sBox[k3]
			k3 = a.sBox[k0]
			k0 = byte(k00 & 255)
		}
		rounds += 2
		mk[idx+4] = k0 ^ mk[idx-12]
		mk[idx+5] = k1 ^ mk[idx-11]
		mk[idx+6] = k2 ^ mk[idx-10]
		mk[idx+7] = k3 ^ mk[idx-9]
	}
	return mk
}

func (a *sixGodAESV3) sumData(data []byte) []byte {
	padded := data
	if len(padded) < 248 {
		tmp := make([]byte, 248)
		copy(tmp, data)
		padded = tmp
	}
	key := make([]byte, 32)
	for i := 0; i < 31; i++ {
		idx := i * 8
		n0 := (int(padded[idx]) >> 4) & 2
		n1 := n0 | (int(padded[idx+1]) & 64)
		n2 := n1 | ((int(padded[idx+2]) >> 2) & 1)
		n3 := n2 | ((int(padded[idx+3]) << 3) & -128)
		n4 := n3 | ((int(padded[idx+4]) >> 1) & 4)
		n5 := n4 | ((int(padded[idx+5]) << 3) & 16)
		n6 := n5 | ((int(padded[idx+6]) << 5) & 32)
		n7 := n6 | ((int(padded[idx+7]) >> 4) & 8)
		key[i] = byte(n7 & 255)
	}
	key[31] = 1
	return key
}

func (a *sixGodAESV3) mixColumnsData(data, key []byte) []byte {
	out := make([]byte, len(data))
	copy(out, data)
	if len(out) < 248 {
		out = append(out, make([]byte, 248-len(out))...)
	}
	for i := 0; i < 31; i++ {
		kk := int(key[i])
		idx := i * 8
		out[idx] = byte(((int(out[idx]) & -33) | (((kk << 4) & 255) & 32)) & 255)
		out[idx+1] = byte(((int(out[idx+1]) & -65) | (kk & 64)) & 255)
		out[idx+2] = byte(((int(out[idx+2]) & -5) | ((kk * 4) & 4)) & 255)
		out[idx+3] = byte(((int(out[idx+3]) & -17) | ((kk >> 3) & 16)) & 255)
		out[idx+4] = byte(((int(out[idx+4]) & -9) | ((kk + kk) & 8)) & 255)
		out[idx+5] = byte(((int(out[idx+5]) & -3) | ((kk >> 3) & 2)) & 255)
		out[idx+6] = byte(((int(out[idx+6]) & -2) | ((kk >> 5) & 1)) & 255)
		out[idx+7] = byte(((int(out[idx+7]) & 127) | (((kk << 4) & 255) & -128)) & 255)
	}
	return out
}

func (a *sixGodAESV3) subBytes(s sixGodAESState) sixGodAESState {
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			s[i][j] = a.sBox[s[i][j]]
		}
	}
	rows := s
	s[0] = rows[a.con2[0]]
	s[1] = rows[a.con2[1]]
	s[2] = rows[a.con2[2]]
	s[3] = rows[a.con2[3]]
	return s
}

func (a *sixGodAESV3) shiftRows(s sixGodAESState) sixGodAESState {
	bs := sixGodState2Bytes(s)
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			s[i][j] = bs[a.order[i*4+j]]
		}
	}
	return s
}

func (a *sixGodAESV3) shiftRowsCon(s sixGodAESState, c [4]int) sixGodAESState {
	for i := 0; i < 4; i++ {
		row := s[i]
		s[i][0] = row[c[0]]
		s[i][1] = row[c[1]]
		s[i][2] = row[c[2]]
		s[i][3] = row[c[3]]
	}
	return s
}

func (a *sixGodAESV3) encryptBlock(plaintext []byte) []byte {
	state := sixGodBytes2State(plaintext)
	state = sixGodAddRoundKeyCon(state, a.keyMatrices[0:4], a.con2)
	for i := 1; i < 3; i++ {
		state = a.subBytes(state)
		state = a.shiftRows(state)
		if i == 1 {
			state = a.shiftRowsCon(state, a.con2)
			state = sixGodMatrixMixColumns(state)
		}
		state = sixGodAddRoundKeyCon(state, a.keyMatrices[i*4:], a.con2)
	}
	state = sixGodAddRoundKey(state, a.keyMatrices[4:])
	return sixGodState2Bytes(state)
}

func (a *sixGodAESV3) encrypt(data, iv []byte) []byte {
	plaintext := a.sumData(data)
	var key []byte
	previous := append([]byte(nil), iv...)
	for i := 0; i < len(plaintext); i += 16 {
		blk := plaintext[i : i+16]
		x := sixGodXorBytes(blk, previous)
		block := a.encryptBlock(x)
		key = append(key, block...)
		previous = block
	}
	mixed := a.mixColumnsData(data, key)
	return append([]byte{key[len(key)-1]}, mixed...)
}

func sixGodGetKeyHash(key []byte, randValue uint32) ([32]byte, []byte) {
	toHash := make([]byte, 68)
	copy(toHash[0:32], key)
	binary.LittleEndian.PutUint32(toHash[32:36], randValue)
	copy(toHash[36:68], key)
	d1 := byte((randValue >> 16) & 255)
	d2 := (uint32(d1) << 11) | (randValue >> 24)
	d2 = d2 ^ (uint32(d1) >> 5) ^ uint32(d1)
	d2 = ^d2
	digest := hongguoSM3(toHash)
	return digest, sixGodU32LE(d2)
}

func sixGodXmxorTwo(data, key []byte) []byte {
	encoded := make([]byte, len(data))
	for i := 0; i < len(data); i++ {
		position := (i * 4) & 28
		d0 := int(key[position])
		d1 := int(key[position+1])
		d2 := (int(sixGodRL8(data[i], 4)) + d0) ^ d1
		d2 = int(sixGodRL8(byte((^d2)&255), 3))
		d2 = ((d2 + d1) & 255) ^ d0
		encoded[len(data)-1-i] = byte((^d2) & 255)
	}
	return encoded
}

func sixGodXmxor(data, key []byte) []byte {
	value := sixGodXmxorTwo(data, key)
	last := len(value) - 1
	lastFlag := int(value[last]) ^ int(value[last-1])
	data0 := int(value[0])
	value[0] = byte(((^lastFlag) + int(value[0])) & 255)
	value[1] = byte(((int(value[0]) ^ int(value[last]) ^ 254) + int(value[1])) & 255)
	value[2] = byte((int(value[2]) + ((lastFlag-data0) ^ int(sixGodRL8(value[1], 3)) ^ 2)) & 255)
	for index := 0; index < len(value)-4; index++ {
		temp := int(sixGodRL8(value[index+2], 3)) ^ int(value[index+1]) ^ (index + 3)
		value[index+3] = byte(((^temp) + int(value[index+3])) & 255)
	}
	value[last] ^= value[last-1]
	sum := 0
	for index := 1; index < len(value); index++ {
		sum += int(value[index])
	}
	value[0] = byte(((int(value[0]) ^ int(value[1])) + sum) & 255)
	return value
}

type sixGodMedusaOpts struct {
	ProtoRand  uint32
	LaunchTime int64
	ProcessID  int64
	HashRand   uint32
	XMRand     uint32
	TimeSec    int64
}

func sixGodRandUint32() uint32 {
	var buf [4]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return 0x9e3779b9
	}
	return binary.LittleEndian.Uint32(buf[:])
}

func sixGodGenMedusaProto(rawURL string, body []byte, khronos uint32, opts sixGodMedusaOpts) (proto, querySm3, bodySm3 []byte, err error) {
	query := ""
	if idx := strings.Index(rawURL, "?"); idx >= 0 {
		rest := rawURL[idx+1:]
		if j := strings.Index(rest, "?"); j >= 0 {
			query = rest[:j]
		} else {
			query = rest
		}
	}
	params, _ := url.ParseQuery(query)
	first := func(key string) string {
		if v, ok := params[key]; ok && len(v) > 0 {
			return v[0]
		}
		return ""
	}
	var bodyMd5Bytes []byte
	if len(body) > 0 {
		sum := md5.Sum(body)
		bodyMd5Bytes = sixGodHexBytes(hex.EncodeToString(sum[:]))
	}
	for len(bodyMd5Bytes) < 16 {
		bodyMd5Bytes = append(bodyMd5Bytes, 0)
	}
	tsBytes := sixGodU32LE(khronos)
	sm3 := hongguoSM3([]byte(query))
	querySm3 = append([]byte(nil), sm3[:]...)
	bodyHashInput := append(append([]byte(nil), []byte(query)...), bodyMd5Bytes...)
	bodyHashInput = append(bodyHashInput, []byte("none")...)
	bodyHash := hongguoSM3(bodyHashInput)
	queryBodyHash := append([]byte(nil), bodyHash[:]...)

	deviceID := first("device_id")
	if deviceID == "" {
		deviceID = first("did")
	}
	versionName := first("version_name")
	if versionName == "" {
		versionName = "7.1.3.32"
	}
	deviceModel := first("device_type")
	brand := first("device_brand")
	osVersion := first("os_version")
	productDevice := first("device_manufacturer")
	if productDevice == "" {
		productDevice = brand
	}
	protoRand := opts.ProtoRand
	if protoRand == 0 {
		protoRand = sixGodRandUint32()
	}
	launchTime := opts.LaunchTime
	if launchTime == 0 {
		launchTime = 100 + int64(sixGodRandUint32()%21)
	}
	processID := opts.ProcessID
	if processID == 0 {
		processID = 10001 + int64(sixGodRandUint32()%2000)
	}
	const reportTs = int64(1728388016635)
	reportTime := opts.TimeSec
	if reportTime == 0 {
		reportTime = int64(khronos)
	}

	var device sixGodProtoBuilder
	device.sint(1, 1)
	device.sint(2, 2)
	device.str(3, "8662")
	device.str(4, deviceID)
	device.str(5, "")
	device.str(6, "!noperm!")
	device.sint(7, -888888)
	device.sint(8, -888888)
	device.sint(9, 3)
	device.sint(10, -888888)
	device.str(11, "!notset!")
	device.str(12, "Asia/Shanghai,8")
	device.str(13, "zh_CN")
	device.sint(14, 4)
	device.float(16, 255.24993896484375)
	device.float(17, 35.58599090576172)
	device.float(18, 3.467449188232422)
	device.float(19, 3.467449188232422)
	device.float(20, 255.1754913330078)
	device.float(21, 42.17544174194336)
	device.str(22, osVersion)
	device.sint(23, 41)
	device.sint(24, 36)
	device.sint(25, reportTs)
	device.sint(26, reportTs)
	device.sint(27, reportTs)
	device.sint(28, reportTs+2)
	device.sint(29, -1)
	device.str(30, deviceModel)
	device.str(31, brand)
	device.str(32, deviceModel)
	device.str(33, deviceModel)
	device.str(34, productDevice)
	device.str(35, brand)
	device.str(36, brand)
	device.sint(38, 31)

	var report sixGodProtoBuilder
	report.sint(1, reportTime)
	report.sint(2, -2)
	report.sint(4, 200)
	report.sint(5, 0)
	report.sint(6, 0)

	var env sixGodProtoBuilder
	env.sint(1, launchTime)
	env.sint(2, 146331399)
	env.sint(3, 146331396)
	env.sint(5, 7)
	env.str(6, "v04.06.04.03-bugfix")
	env.sint(7, processID)
	env.msg(12, device.out)
	env.msg(13, report.out)
	env.str(14, versionName)

	hash, err := sixGodHashF13(querySm3, bodyMd5Bytes, tsBytes, khronos)
	if err != nil {
		return nil, nil, nil, err
	}
	bodySm3 = hash

	var request sixGodProtoBuilder
	request.sint(1, 111)
	request.sint(2, 10)
	request.sint(3, 694367)
	request.sint(5, 586952199)

	var medusa sixGodProtoBuilder
	medusa.bytes(1, sixGodHexBytes("f7e85ffad7d7dc3bd62ac87057cf6118"))
	medusa.sint(2, 3)
	medusa.sint(3, int64(protoRand))
	medusa.str(4, "8662")
	medusa.str(5, deviceID)
	medusa.str(6, "1588093228")
	medusa.str(7, versionName)
	medusa.str(8, "v04.06.04-ml-android")
	medusa.sint(9, 67503104)
	medusa.bytes(10, []byte{64, 1, 0, 0, 0, 0, 0, 0})
	medusa.sint(12, int64(khronos))
	medusa.bytes(13, hash)
	medusa.bytes(14, querySm3[:6])
	medusa.msg(15, request.out)
	medusa.str(16, "")
	medusa.sint(17, int64(khronos))
	medusa.bytes(18, nil)
	medusa.bytes(19, queryBodyHash)
	medusa.str(20, "none")
	medusa.sint(21, 312)
	medusa.msg(23, env.out)
	medusa.str(24, `{"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,"kd":0,"fkd":3672518972,"pd":-1872573247,"dyn":"","do":0,"tk":true}`)
	return medusa.out, querySm3, bodySm3, nil
}

func sixGodGenMedusa(rawURL string, body []byte, khronos uint32, opts sixGodMedusaOpts) (string, error) {
	configKey := sixGodHexBytes("f1593376766ea98d34f31b057a9d5be4")
	configIv := sixGodHexBytes("1fe109a4125283f418de9e051a969e12")
	signKey := sixGodHexBytes("8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5")
	proto, querySm3, bodySm3, err := sixGodGenMedusaProto(rawURL, body, khronos, opts)
	if err != nil {
		return "", err
	}
	hashRand := opts.HashRand
	if hashRand == 0 {
		hashRand = sixGodRandUint32()
	}
	xmRand := opts.XMRand
	if xmRand == 0 {
		xmRand = sixGodRandUint32()
	}
	khKey, khSeed := sixGodGetKeyHash(signKey, hashRand)
	mixed := sixGodXmxor(proto, khKey[:])
	mixed = append([]byte{64, 1, 0, 0, 0, 0, 0, 0}, mixed...)
	for i, j := 0, len(mixed)-1; i < j; i, j = i+1, j-1 {
		mixed[i], mixed[j] = mixed[j], mixed[i]
	}
	for index := range mixed {
		mixed[index] ^= khSeed[(^index)&3]
	}
	hashBytes := sixGodU32LE(hashRand)
	checkBit := (uint32(querySm3[0]&63) << 14) | 0x18000001 | (uint32(bodySm3[0]&63) << 8)
	out := []byte{0x35}
	out = append(out, sixGodU32LE(xmRand)...)
	out = append(out, sixGodU32LE(checkBit)...)
	out = append(out, mixed...)
	out = append(out, hashBytes[2:]...)
	aes, err := sixGodNewAESV3(configKey, khronos)
	if err != nil {
		return "", err
	}
	encrypted := aes.encrypt(out, configIv)
	version := sixGodHexBytes("03000000f7e85ffad7d7dc3bd62ac87057cf6118")
	var versionOr []byte
	for i := 0; i < 20; i += 4 {
		v := binary.LittleEndian.Uint32(version[i : i+4]) ^ khronos
		versionOr = append(versionOr, sixGodU32LE(v)...)
	}
	final := append(versionOr, hashBytes[0:2]...)
	final = append(final, 0, 1)
	final = append(final, encrypted...)
	return sixGodB64(final), nil
}
