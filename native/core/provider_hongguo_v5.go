package core

// V5 signing for the v04.10.03 playback endpoint.
//
// Go port of upstream fqapp sign/v5.rs (PR #425, 2b16621e + d24f229a).
// Protocol data and the transform structure come from N3urda/hongguoTV
// (GPL-3.0-only) Signer.kt / AesV3.kt / V5Constants.kt / MobilePlayback.kt
// at 18c37c2a, cross-checked against beilunyang/openhongguo PR 13 (788103f6).
// The caller supplies the exact gzip bytes that will be sent; this module
// hashes those bytes and never compresses the payload.
//
// Only the playback endpoint (multi_video_model/player/v1) uses V5. The
// detail / feed / search chains keep the legacy six-god signer in
// provider_hongguo_player_sign.go and provider_hongguo_sixgod.go; the two
// signers share only the verified-identical primitives sixGodGetIv and
// hongguoSM3. hash_f13_v5, sum_md5, xmxor, AesV5 and medusa are V5-only
// and intentionally NOT reused from the six-god implementations, whose
// seeds, rounds and tables differ.

import (
	"crypto/md5"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"math/bits"
	"net/http"
	"strings"
	"sync"
	"time"
)

const (
	hongguoV5AppID       = 8662
	hongguoV5VersionCode = "74332"
	hongguoV5VersionName = "7.4.3.32"
	hongguoV5Channel     = "vivo_8662_64"
	hongguoV5DeviceType  = "PGT-AN10"
	hongguoV5OSVersion   = "12"
	hongguoV5License     = 646637794
	hongguoV5UserAgent   = "com.phoenix.read/73932 (Linux; U; Android 12; zh_CN_#Hans; PGT-AN10; Build/V417IR;tt-ok/3.12.13.20)"
	// hongguoV5DeviceBrand / hongguoV5OSAPI / hongguoV5Resolution /
	// hongguoV5DPI: the official capture values folded into the 28-field
	// playback envelope (upstream 2f31ba83). The anonymous door uses its own
	// resolution/DPI/ROM values below.
	hongguoV5DeviceBrand = "HONOR"
	hongguoV5OSAPI       = "31"
	hongguoV5Resolution  = "1312*2848"
	hongguoV5DPI         = "480"
	// hongguoAnonResolution / hongguoAnonDPI / hongguoAnonROMVersion: the
	// anonymous enhanced door's own values (upstream bef83c90, lvguo-tv
	// v2.0.8 reference vectors).
	hongguoAnonResolution = "1920*1080"
	hongguoAnonDPI        = "280"
	hongguoAnonROMVersion = "V417IR+release-keys"
)

var hongguoV5Magic = [16]byte{
	0x2d, 0x4b, 0x4f, 0xca, 0x49, 0x75, 0x0d, 0x43, 0x3f, 0xb5, 0xae, 0x2c, 0x22, 0x6d, 0xcc, 0x56,
}

var hongguoV5SignKey = [32]byte{
	0xb2, 0x3c, 0x2a, 0x47, 0x0a, 0x20, 0xd1, 0x05, 0xdc, 0x3f, 0x8c, 0x44, 0x38, 0xf8, 0x27, 0x2e,
	0xd4, 0x6d, 0x6c, 0x89, 0xff, 0xdc, 0xde, 0xdd, 0x51, 0x08, 0x69, 0x8d, 0x26, 0xe9, 0x48, 0x9d,
}

// hongguoV5Identity: anonymous device values carried in the V5 query and
// Medusa message. cdid never comes out empty: hongguoCDID generates a stable
// value when the persisted state lacks one (upstream falls back to openudid).
type hongguoV5Identity struct {
	DeviceID  string
	InstallID string
	CDID      string
}

// hongguoV5Request: a request ready to be sent with the caller's original
// compressed body.
type hongguoV5Request struct {
	URL     string
	Headers http.Header
}

type hongguoV5ProcessState struct {
	nonce     string
	startedMS int64
}

type hongguoV5Entropy struct {
	helios      uint32
	medusaNonce uint32
	packed      uint32
	message     uint32
}

func hongguoV5LE32(value uint32) [4]byte {
	var out [4]byte
	binary.LittleEndian.PutUint32(out[:], value)
	return out
}

func hongguoV5MD5(data []byte) [16]byte {
	return md5.Sum(data)
}

var (
	hongguoV5StateOnce sync.Once
	hongguoV5State     hongguoV5ProcessState
)

func hongguoV5LoadProcessState(nowMS int64) hongguoV5ProcessState {
	hongguoV5StateOnce.Do(func() {
		var nonce [18]byte
		_, _ = rand.Read(nonce[:])
		hongguoV5State = hongguoV5ProcessState{
			nonce:     base64.RawURLEncoding.EncodeToString(nonce[:]),
			startedMS: nowMS,
		}
	})
	return hongguoV5State
}

func hongguoV5RandomEntropy() hongguoV5Entropy {
	var raw [16]byte
	_, _ = rand.Read(raw[:])
	return hongguoV5Entropy{
		helios:      binary.LittleEndian.Uint32(raw[0:4]),
		medusaNonce: binary.LittleEndian.Uint32(raw[4:8]),
		packed:      binary.LittleEndian.Uint32(raw[8:12]),
		message:     binary.LittleEndian.Uint32(raw[12:16]),
	}
}

func hongguoV5AppendVarint(out []byte, value uint64) []byte {
	for value > 0x7f {
		out = append(out, byte(value&0x7f)|0x80)
		value >>= 7
	}
	return append(out, byte(value))
}

func hongguoV5Zigzag(value int64) uint64 {
	if value < 0 {
		return uint64(-value*2 - 1)
	}
	return uint64(value) * 2
}

type hongguoV5Field struct {
	tag     uint32
	sint    int64
	float   float32
	bytes   []byte
	isBytes bool
	isFloat bool
}

func hongguoV5SintField(tag uint32, value int64) hongguoV5Field {
	return hongguoV5Field{tag: tag, sint: value}
}

func hongguoV5FloatField(tag uint32, value float32) hongguoV5Field {
	return hongguoV5Field{tag: tag, float: value, isFloat: true}
}

func hongguoV5BytesField(tag uint32, value []byte) hongguoV5Field {
	return hongguoV5Field{tag: tag, bytes: value, isBytes: true}
}

func hongguoV5StringField(tag uint32, value string) hongguoV5Field {
	return hongguoV5Field{tag: tag, bytes: []byte(value), isBytes: true}
}

func hongguoV5Proto(fields []hongguoV5Field) []byte {
	var out []byte
	for _, field := range fields {
		if field.isFloat {
			out = hongguoV5AppendVarint(out, uint64(field.tag)<<3|5)
			bits := hongguoV5LE32(math.Float32bits(field.float))
			out = append(out, bits[:]...)
			continue
		}
		if field.isBytes {
			if len(field.bytes) == 0 {
				continue
			}
			out = hongguoV5AppendVarint(out, uint64(field.tag)<<3|2)
			out = hongguoV5AppendVarint(out, uint64(len(field.bytes)))
			out = append(out, field.bytes...)
			continue
		}
		out = hongguoV5AppendVarint(out, uint64(field.tag)<<3)
		out = hongguoV5AppendVarint(out, hongguoV5Zigzag(field.sint))
	}
	return out
}

// hongguoV5BranchIV: three chained get_iv passes over the query SM3, the body
// MD5 and the little-endian timestamp. sixGodGetIv is operation-identical to
// upstream get_iv (verified side by side), so it is reused here.
func hongguoV5BranchIV(queryHash [32]byte, bodyMD5 [16]byte, ts uint32) uint32 {
	step := sixGodGetIv(0x20230928, queryHash[:])
	step = sixGodGetIv(step, bodyMD5[:])
	tsBytes := hongguoV5LE32(ts)
	return sixGodGetIv(step, tsBytes[:])
}

func hongguoV5SumMD5(data [16]byte) uint32 {
	check := uint32(0x20220420)
	for index := 0; index < 12; index++ {
		shift := uint(3)
		if index&1 != 0 {
			shift = 5
		}
		temp := (check >> shift) ^ check
		if index&1 == 0 {
			check = uint32(data[index]) ^ check<<7
		} else {
			check = ^(uint32(data[index]) | check<<11)
		}
		check ^= temp
	}
	return (check | 4) ^ 0x01000000
}

func hongguoV5HashF13(queryHash [32]byte, bodyMD5 [16]byte, ts uint32) [20]byte {
	// The seed, schedule, state layout and tag are V5 wire constants from the
	// public implementations above. They are intentionally transcribed with
	// explicit indices; do not "simplify" them into another hash family.
	const seed = uint32(0x9d4a97c2)
	rounds := [11]int{96, 1, 3, 4, 0, 6, 5, 2, 0, 7, 7}
	initialTable := [8]uint32{
		0x7aba4fc8,
		0x67166507,
		0x6403fa00,
		0x340f512f,
		984304912,
		3005047866,
		2874125293,
		2152413264,
	}

	count := seed + ts
	var table [64]uint32
	for i, value := range hongguoV5HashTable {
		table[i] = bits.RotateLeft32(value, -int((count+1)&255))
	}

	shift := (count + 2) & 7
	var pad [4]byte
	for index, value := range []uint32{0xfa, 0x45, 0x61, 0xd7} {
		pad[index] = byte((value | (value << 8)) >> shift)
	}

	var data [64]byte
	copy(data[0:32], queryHash[:])
	copy(data[32:48], bodyMD5[:])
	tsBytes := hongguoV5LE32(ts)
	copy(data[48:52], tsBytes[:])
	copy(data[52:56], pad[:])
	copy(data[56:64], []byte{0, 0, 0, 0, 0, 0, 0x01, 0xa0})

	words := make([]uint32, 0, 128)
	for i := 0; i < 16; i++ {
		words = append(words, binary.BigEndian.Uint32(data[i*4:]))
	}
	for index := 0; index < 112; index++ {
		x := words[index+1]
		y := words[index+14]
		value := words[index] + words[index+9] +
			(bits.RotateLeft32(x, 14) ^ bits.RotateLeft32(x, 25) ^ (x >> 3)) +
			(bits.RotateLeft32(y, 13) ^ bits.RotateLeft32(y, 15) ^ (y >> 10))
		words = append(words, value)
	}

	var initial [8]uint32
	for i, value := range initialTable {
		initial[i] = bits.RotateLeft32(value, -int(count))
	}
	state := initial
	for index := 0; index < rounds[0]; index++ {
		base := seed + uint32(index)
		n1 := ((state[rounds[3]] ^ state[rounds[4]]) & state[rounds[1]]) ^ state[rounds[3]]
		x := state[rounds[1]]
		n2 := bits.RotateLeft32(x, 26) ^ bits.RotateLeft32(x, 21) ^ bits.RotateLeft32(x, 7)
		n4 := words[base&127] + n1 + n2 + table[base&63] + state[rounds[5]]
		y := state[rounds[2]]
		n5 := bits.RotateLeft32(y, 30) ^ bits.RotateLeft32(y, 19) ^ bits.RotateLeft32(y, 10)
		n6 := (y & state[rounds[6]]) | ((y | state[rounds[6]]) & state[rounds[7]])
		old := state[rounds[9]]
		var rotated [8]uint32
		rotated[0] = state[7]
		copy(rotated[1:], state[:7])
		state = rotated
		state[rounds[10]] = n5 + n6 + n4
		state[rounds[8]] = old + n4
	}

	var expanded [32]byte
	for index, value := range state {
		binary.BigEndian.PutUint32(expanded[index*4:], value+initial[index])
	}
	var folded [16]byte
	for index := 0; index < 16; index++ {
		folded[index] = expanded[index] ^ expanded[index+16]
	}

	var output [20]byte
	copy(output[:16], folded[:])
	check := hongguoV5LE32(hongguoV5SumMD5(folded) | 0x20)
	copy(output[16:], check[:])
	return output
}

func hongguoV5XMXOR(data, key []byte) []byte {
	length := len(data)
	encoded := make([]byte, length)
	for index, value := range data {
		at := (index * 4) & 28
		d0 := uint32(key[at])
		d1 := uint32(key[at+1])
		v := uint32(value)
		mixed := ((((v << 4) | (v >> 4)) & 0xff) + d0) & 0xff
		mixed = (^mixed) ^ d1
		masked := mixed & 0xff
		mixed = ((((masked << 3) | (masked >> 5)) & 0xff) + d1) & 0xff
		mixed = (mixed ^ d0) & 0xff
		encoded[length-index-1] = byte(^mixed)
	}

	last := encoded[length-1] ^ encoded[length-2]
	first := encoded[0]
	encoded[0] = (^last) + first
	encoded[1] = (encoded[0] ^ encoded[length-1] ^ 0xfe) + encoded[1]
	encoded[2] = encoded[2] + ((last - first) ^ bits.RotateLeft8(encoded[1], 3) ^ 2)

	for index := 0; index < length-4; index++ {
		temp := bits.RotateLeft8(encoded[index+2], 3) ^ encoded[index+1] ^ (byte(index) + 3)
		encoded[index+3] = (^temp) + encoded[index+3]
	}

	encoded[length-1] ^= encoded[length-2]
	var total byte
	for _, value := range encoded[1:] {
		total += value
	}
	encoded[0] = (encoded[0] ^ encoded[1]) + total
	return encoded
}

type hongguoV5AES struct {
	sbox  [256]byte
	con   [4]int
	order [16]int
	keys  [12][4]byte
}

func hongguoV5NewAES(key [16]byte, ts uint32) hongguoV5AES {
	initialTable := [4]uint32{0xbbb5de72, 0xd4638d5b, 0x92a5f73b, 0x89f8a1c9}
	conTable := [4][4]int{{2, 0, 3, 1}, {1, 3, 2, 0}, {3, 2, 1, 0}, {2, 3, 1, 0}}
	orderTable := [4][16]int{
		{0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11},
		{0, 9, 14, 11, 4, 13, 2, 3, 8, 1, 6, 15, 12, 5, 10, 7},
		{0, 9, 14, 3, 4, 13, 2, 15, 8, 1, 6, 11, 12, 5, 10, 7},
		{0, 9, 14, 15, 4, 13, 2, 3, 8, 1, 6, 11, 12, 5, 10, 7},
	}

	word := int(ts & 3)
	initial := initialTable[word]
	var sbox [256]byte
	copy(sbox[:], hongguoV5SBOX[word*256:(word+1)*256])

	var expanded [48]byte
	initialBytes := hongguoV5LE32(initial)
	for offset := 0; offset < 4; offset++ {
		copy(expanded[offset*4:], initialBytes[:])
	}
	for index := 0; index < 16; index++ {
		expanded[index] ^= key[index]
	}

	rotation := uint32(8)
	for index := 4; index < 12; index++ {
		at := 4 * (index - 1)
		a, b, c, d := expanded[at], expanded[at+1], expanded[at+2], expanded[at+3]
		if index&3 == 0 {
			mixed := ((initial >> (rotation & 24)) ^ uint32(sbox[b])) & 0xff
			b = sbox[c]
			c = sbox[d]
			d = sbox[a]
			a = byte(mixed)
		}
		rotation += 2
		expanded[at+4] = a ^ expanded[at-12]
		expanded[at+5] = b ^ expanded[at-11]
		expanded[at+6] = c ^ expanded[at-10]
		expanded[at+7] = d ^ expanded[at-9]
	}

	var keys [12][4]byte
	for index := 0; index < 12; index++ {
		copy(keys[index][:], expanded[index*4:])
	}
	return hongguoV5AES{sbox: sbox, con: conTable[word], order: orderTable[word], keys: keys}
}

func (aesv5 hongguoV5AES) addCon(rows *[4][4]byte, start int) {
	for row := 0; row < 4; row++ {
		for column := 0; column < 4; column++ {
			rows[row][column] ^= aesv5.keys[start+row][aesv5.con[column]]
		}
	}
}

func (aesv5 hongguoV5AES) block(value [16]byte) [16]byte {
	var rows [4][4]byte
	for row := 0; row < 4; row++ {
		copy(rows[row][:], value[row*4:])
	}
	aesv5.addCon(&rows, 0)

	for round := 1; round <= 2; round++ {
		for row := 0; row < 4; row++ {
			for column := 0; column < 4; column++ {
				rows[row][column] = aesv5.sbox[rows[row][column]]
			}
		}

		previous := rows
		for row := 0; row < 4; row++ {
			rows[row] = previous[aesv5.con[row]]
		}

		var flat [16]byte
		for row := 0; row < 4; row++ {
			copy(flat[row*4:], rows[row][:])
		}
		for index := 0; index < 16; index++ {
			rows[index/4][index%4] = flat[aesv5.order[index]]
		}

		if round == 1 {
			for row := 0; row < 4; row++ {
				previous := rows[row]
				for column := 0; column < 4; column++ {
					rows[row][column] = previous[aesv5.con[column]]
				}
			}

			double := func(value byte) byte {
				doubled := value << 1
				if value&0x80 != 0 {
					doubled ^= 0x1b
				}
				return doubled
			}
			for column := 0; column < 4; column++ {
				sum := rows[0][column] ^ rows[1][column] ^ rows[2][column] ^ rows[3][column]
				first := rows[0][column]
				rows[0][column] ^= sum ^ double(rows[0][column]^rows[1][column])
				rows[1][column] ^= sum ^ double(rows[1][column]^rows[2][column])
				rows[2][column] ^= sum ^ double(rows[2][column]^rows[3][column])
				rows[3][column] ^= sum ^ double(rows[3][column]^first)
			}
		}

		aesv5.addCon(&rows, round*4)
	}

	for row := 0; row < 4; row++ {
		for column := 0; column < 4; column++ {
			rows[row][column] ^= aesv5.keys[4+row][column]
		}
	}

	var output [16]byte
	for row := 0; row < 4; row++ {
		copy(output[row*4:], rows[row][:])
	}
	return output
}

func (aesv5 hongguoV5AES) encrypt(source []byte, iv [16]byte) ([]byte, error) {
	wire := [8]uint8{6, 5, 3, 4, 2, 7, 1, 0}
	compact := [8]uint8{1, 7, 3, 6, 2, 0, 4, 5}

	if len(source) < 248 {
		return nil, errors.New("V5 AES payload is shorter than 248 bytes")
	}

	var plain [32]byte
	for index := 0; index < 31; index++ {
		for position := 0; position < 8; position++ {
			bit := (source[index*8+position] >> wire[position]) & 1
			plain[index] |= bit << compact[position]
		}
	}
	plain[31] = 1

	var head [16]byte
	for index := 0; index < 16; index++ {
		head[index] = plain[index] ^ iv[index]
	}
	first := aesv5.block(head)

	var tail [16]byte
	for index := 0; index < 16; index++ {
		tail[index] = plain[16+index] ^ first[index]
	}
	second := aesv5.block(tail)

	var cipherBits [32]byte
	copy(cipherBits[:16], first[:])
	copy(cipherBits[16:], second[:])

	output := append([]byte(nil), source...)
	for index := 0; index < 31; index++ {
		for position := 0; position < 8; position++ {
			at := index*8 + position
			bit := (cipherBits[index] >> compact[position]) & 1
			mask := byte(1) << wire[position]
			output[at] = (output[at] &^ mask) | (bit << wire[position])
		}
	}

	result := make([]byte, 0, len(output)+1)
	result = append(result, cipherBits[31])
	result = append(result, output...)
	return result, nil
}

func hongguoV5Helios(ts uint32, random uint32) string {
	prefix := hongguoV5LE32(random)
	return hongguoPlayerLadonWithLicense("8662", hongguoV5License, ts, prefix[:])
}

func hongguoV5Medusa(queryHash [32]byte, bodyMD5 [16]byte, ts uint32, identity hongguoV5Identity, state hongguoV5ProcessState, entropy hongguoV5Entropy) (string, error) {
	appID := "8662"
	license := "646637794"
	f13 := hongguoV5HashF13(queryHash, bodyMD5, ts)
	var flags [8]byte

	device := hongguoV5Proto([]hongguoV5Field{
		hongguoV5SintField(1, 1),
		hongguoV5SintField(2, 2),
		hongguoV5StringField(3, appID),
		hongguoV5StringField(4, identity.DeviceID),
		hongguoV5StringField(5, state.nonce),
		hongguoV5StringField(6, "!noperm!"),
		hongguoV5StringField(12, "Asia/Shanghai,8"),
		hongguoV5StringField(13, "zh_CN"),
		hongguoV5StringField(22, hongguoV5OSVersion),
		hongguoV5SintField(25, state.startedMS),
		hongguoV5StringField(30, hongguoV5DeviceType),
		hongguoV5StringField(31, "HONOR"),
		hongguoV5StringField(32, hongguoV5DeviceType),
		hongguoV5StringField(34, "HONOR"),
	})

	environment := hongguoV5Proto([]hongguoV5Field{
		hongguoV5StringField(6, "v04.10.03.04-bugfix"),
		hongguoV5StringField(8, hongguoV5Channel),
		hongguoV5BytesField(12, device),
		hongguoV5StringField(14, hongguoV5VersionName),
	})

	message := hongguoV5Proto([]hongguoV5Field{
		hongguoV5BytesField(1, hongguoV5Magic[:]),
		hongguoV5SintField(2, 5),
		hongguoV5SintField(3, int64(entropy.message)),
		hongguoV5StringField(4, appID),
		hongguoV5StringField(5, identity.DeviceID),
		hongguoV5StringField(6, license),
		hongguoV5StringField(7, hongguoV5VersionName),
		hongguoV5StringField(8, "v04.10.03-ml-android"),
		hongguoV5SintField(9, 0x040a0300),
		hongguoV5BytesField(10, flags[:]),
		hongguoV5SintField(12, int64(ts)),
		hongguoV5BytesField(13, f13[:]),
		hongguoV5BytesField(14, queryHash[:6]),
		hongguoV5BytesField(15, hongguoV5Proto([]hongguoV5Field{
			hongguoV5SintField(1, 1),
			hongguoV5SintField(2, 1),
			hongguoV5SintField(3, 1),
			hongguoV5SintField(5, 1),
		})),
		hongguoV5SintField(17, int64(ts)),
		hongguoV5StringField(20, "none"),
		hongguoV5SintField(21, 377),
		hongguoV5BytesField(23, environment),
		hongguoV5StringField(24, `{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}`),
	})
	if len(message) < 4 {
		return "", errors.New("V5 medusa message is too short")
	}

	seedInput := make([]byte, 0, 68)
	seedInput = append(seedInput, hongguoV5SignKey[:]...)
	nonceBytes := hongguoV5LE32(entropy.medusaNonce)
	seedInput = append(seedInput, nonceBytes[:]...)
	seedInput = append(seedInput, hongguoV5SignKey[:]...)
	seedHash := hongguoSM3(seedInput)

	high := (entropy.medusaNonce >> 16) & 0xff
	seedWord := (high<<11 | (entropy.medusaNonce >> 24)) ^ (high >> 5) ^ high
	seed := hongguoV5LE32(^seedWord)

	transformed := append(append([]byte(nil), flags[:]...), hongguoV5XMXOR(message, seedHash[:])...)
	for left, right := 0, len(transformed)-1; left < right; left, right = left+1, right-1 {
		transformed[left], transformed[right] = transformed[right], transformed[left]
	}
	for index := range transformed {
		transformed[index] ^= seed[3-(index&3)]
	}

	check := uint32(0x18000001) | ((uint32(queryHash[0]) & 63) << 14) | ((uint32(f13[0]) & 63) << 8)
	packed := make([]byte, 0, 11+len(transformed))
	packed = append(packed, 0xca)
	packedEntropy := hongguoV5LE32(entropy.packed)
	packed = append(packed, packedEntropy[:]...)
	checkBytes := hongguoV5LE32(check)
	packed = append(packed, checkBytes[:]...)
	packed = append(packed, transformed...)
	packed = append(packed, byte(entropy.medusaNonce>>16), byte(entropy.medusaNonce>>24))

	key := hongguoV5MD5(hongguoV5SignKey[:16])
	iv := hongguoV5MD5(hongguoV5SignKey[16:])
	encrypted, err := hongguoV5NewAES(key, ts).encrypt(packed, iv)
	if err != nil {
		return "", err
	}

	prefix := hongguoV5LE32(5)
	prefixBytes := append(append([]byte(nil), prefix[:]...), hongguoV5Magic[:]...)
	timestamp := hongguoV5LE32(ts)
	for index := range prefixBytes {
		prefixBytes[index] ^= timestamp[index&3]
	}

	output := append([]byte(nil), prefixBytes...)
	output = append(output, byte(entropy.medusaNonce), byte(entropy.medusaNonce>>8), 0, 1)
	output = append(output, encrypted...)
	return base64.StdEncoding.EncodeToString(output), nil
}

func hongguoV5EncodeComponent(value string) string {
	const hexDigits = "0123456789ABCDEF"
	var out strings.Builder
	out.Grow(len(value))
	for i := 0; i < len(value); i++ {
		b := value[i]
		switch {
		case b >= 'A' && b <= 'Z', b >= 'a' && b <= 'z', b >= '0' && b <= '9',
			b == '-', b == '_', b == '.', b == '*', b == '~':
			out.WriteByte(b)
		default:
			out.WriteByte('%')
			out.WriteByte(hexDigits[b>>4])
			out.WriteByte(hexDigits[b&0xf])
		}
	}
	return out.String()
}

// hongguoV5PlaybackQuery: the shared playback query bag. The 12 identity
// fields come first, then the 16 official-capture fields (upstream 2f31ba83),
// then the door's own fields (extra), then _rticket last. The query hash and
// the _rticket branch are computed over the whole 28-field string.
func hongguoV5PlaybackQuery(identity hongguoV5Identity, ticket int64, appID string, extra [][2]string) string {
	pairs := [][2]string{
		{"aid", appID},
		{"app_name", "novelread"},
		{"version_code", hongguoV5VersionCode},
		{"version_name", hongguoV5VersionName},
		{"channel", hongguoV5Channel},
		{"device_platform", "android"},
		{"device_type", hongguoV5DeviceType},
		{"os_version", hongguoV5OSVersion},
		{"update_version_code", hongguoV5VersionCode},
		{"iid", identity.InstallID},
		{"cdid", identity.CDID},
		{"device_id", identity.DeviceID},
		{"ac", "wifi"},
		{"os", "android"},
		{"ssmix", "a"},
		{"device_brand", hongguoV5DeviceBrand},
		{"language", "zh"},
		{"os_api", hongguoV5OSAPI},
		{"manifest_version_code", hongguoV5VersionCode},
		{"resolution", hongguoV5Resolution},
		{"dpi", hongguoV5DPI},
		{"host_abi", "arm64-v8a"},
		{"dragon_device_type", "phone"},
		{"pv_player", hongguoV5VersionCode},
		{"compliance_status", "0"},
		{"need_personal_recommend", "1"},
		{"player_so_load", "1"},
		{"is_android_pad_screen", "0"},
	}
	pairs = append(pairs, extra...)
	var query strings.Builder
	for _, pair := range pairs {
		if query.Len() > 0 {
			query.WriteByte('&')
		}
		query.WriteString(hongguoV5EncodeComponent(pair[0]))
		query.WriteByte('=')
		query.WriteString(hongguoV5EncodeComponent(pair[1]))
	}
	query.WriteString("&_rticket=")
	query.WriteString(fmt.Sprintf("%d", ticket))
	return query.String()
}

// hongguoV5PlaybackEnvelopeIsFull: the 16 official-capture fields must all be
// present with a non-empty value (upstream playback_envelope_is_full).
func hongguoV5PlaybackEnvelopeIsFull(query string) bool {
	expected := []string{
		"ac", "os", "ssmix", "device_brand", "language", "os_api",
		"manifest_version_code", "resolution", "dpi", "host_abi",
		"dragon_device_type", "pv_player", "compliance_status",
		"need_personal_recommend", "player_so_load", "is_android_pad_screen",
	}
	for _, name := range expected {
		found := false
		for _, pair := range strings.Split(query, "&") {
			key, value, ok := strings.Cut(pair, "=")
			if ok && key == name && value != "" {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// hongguoV5SignPlayback signs one request for
// /novel/player/multi_video_model/player/v1.
//
// compressedBody must be the exact gzip-compressed bytes that the HTTP client
// sends. base must be the endpoint URL without a query string.
func hongguoV5SignPlayback(base string, compressedBody []byte, identity hongguoV5Identity) (hongguoV5Request, error) {
	nowMS := time.Now().UnixMilli()
	return hongguoV5SignPlaybackAt(base, compressedBody, identity, nowMS, hongguoV5LoadProcessState(nowMS), hongguoV5RandomEntropy())
}

// hongguoV5SignPlaybackAt is the deterministic seam for tests: the caller
// fixes the clock, the process state and the entropy. Production callers use
// hongguoV5SignPlayback.
func hongguoV5SignPlaybackAt(base string, compressedBody []byte, identity hongguoV5Identity, nowMS int64, state hongguoV5ProcessState, entropy hongguoV5Entropy) (hongguoV5Request, error) {
	return hongguoV5SignRequestAt(base, nil, compressedBody, identity, nowMS, state, entropy, false)
}

// hongguoV5SignPlaybackGet signs a GET for a door of the same family, e.g.
// the video_tab model door (upstream sign_playback_v5_get). extra carries
// the door's own query fields. A GET carries no body, so the branch is
// selected by the digest of zero bytes and the body-describing headers
// (Content-Type, Content-Encoding, X-Ss-Stub) are omitted.
func hongguoV5SignPlaybackGet(base string, extra [][2]string, identity hongguoV5Identity) (hongguoV5Request, error) {
	nowMS := time.Now().UnixMilli()
	return hongguoV5SignPlaybackGetAt(base, extra, identity, nowMS, hongguoV5LoadProcessState(nowMS), hongguoV5RandomEntropy())
}

// hongguoV5SignPlaybackGetAt is the deterministic seam for the GET form.
func hongguoV5SignPlaybackGetAt(base string, extra [][2]string, identity hongguoV5Identity, nowMS int64, state hongguoV5ProcessState, entropy hongguoV5Entropy) (hongguoV5Request, error) {
	return hongguoV5SignRequestAt(base, extra, nil, identity, nowMS, state, entropy, true)
}

// hongguoV5SignRequestAt: the shared ticket loop for the POST and GET forms.
// For the GET form the body digest is the digest of zero bytes.
func hongguoV5SignRequestAt(base string, extra [][2]string, compressedBody []byte, identity hongguoV5Identity, nowMS int64, state hongguoV5ProcessState, entropy hongguoV5Entropy, isGet bool) (hongguoV5Request, error) {
	if base == "" {
		return hongguoV5Request{}, errors.New("V5 playback base URL is empty")
	}
	if strings.ContainsAny(base, "?#") {
		return hongguoV5Request{}, errors.New("V5 playback base URL must not contain a query or fragment")
	}
	if identity.DeviceID == "" || identity.InstallID == "" || identity.CDID == "" {
		return hongguoV5Request{}, errors.New("V5 playback identity is incomplete")
	}
	seconds := nowMS / 1000
	if seconds < 0 || seconds > math.MaxUint32 {
		return hongguoV5Request{}, errors.New("V5 playback timestamp is outside the protocol range")
	}
	ts := uint32(seconds)
	bodyMD5 := hongguoV5MD5(compressedBody)
	appID := "8662"

	for offset := int64(0); offset < 1024; offset++ {
		ticket := nowMS + offset
		if ticket < nowMS {
			return hongguoV5Request{}, errors.New("V5 playback request ticket overflow")
		}
		query := hongguoV5PlaybackQuery(identity, ticket, appID, extra)
		queryHash := hongguoSM3([]byte(query))
		if hongguoV5BranchIV(queryHash, bodyMD5, ts)&15 != 12 {
			continue
		}
		medusa, err := hongguoV5Medusa(queryHash, bodyMD5, ts, identity, state, entropy)
		if err != nil {
			return hongguoV5Request{}, err
		}
		headers := http.Header{
			"X-Khronos":  {fmt.Sprintf("%d", ts)},
			"X-Helios":   {hongguoV5Helios(ts, entropy.helios)},
			"X-Medusa":   {medusa},
			"User-Agent": {hongguoV5UserAgent},
			"Accept":     {"application/json"},
		}
		if !isGet {
			headers["Content-Type"] = []string{"application/json; charset=utf-8"}
			headers["Content-Encoding"] = []string{"gzip"}
			headers["X-Ss-Stub"] = []string{strings.ToUpper(hex.EncodeToString(bodyMD5[:]))}
		}
		return hongguoV5Request{URL: base + "?" + query, Headers: headers}, nil
	}
	return hongguoV5Request{}, errors.New("V5 playback signing could not find the branch-12 ticket")
}

// ---------------------------------------------------------------------------
// Anonymous enhanced V5 door (upstream bef83c90).
//
// Ported field-for-field from Amor5207/lvguo-tv v2.0.8 commit 32fcdfdb
// (web/internal/sign/v5.go::medusaV5 / SignMobileV5 and
// web/internal/lvguoplay/legacy.go::requestLegacy), via upstream fqapp
// sign/v5.rs (anonymous_medusa / anonymous_playback_query /
// sign_anonymous_playback_v5). The legacy medusa above stays untouched
// because the legacy playback door still depends on its profile.
// ---------------------------------------------------------------------------

// hongguoAnonV5Identity: anonymous registration identity used only by the
// enhanced playback door. EGDI is empty until the register response returns
// one (klink_egdi); the query omits it while empty.
type hongguoAnonV5Identity struct {
	DeviceID  string
	InstallID string
	CDID      string
	EGDI      string
}

type hongguoAnonEntropy struct {
	gorgon      uint16
	helios      uint32
	envLaunch   int64
	envPID      int64
	message     uint32
	medusaNonce uint32
	packed      uint32
}

func hongguoAnonRandomEntropy() hongguoAnonEntropy {
	var raw [22]byte
	_, _ = rand.Read(raw[:])
	return hongguoAnonEntropy{
		gorgon:      binary.LittleEndian.Uint16(raw[0:2]),
		helios:      binary.LittleEndian.Uint32(raw[2:6]),
		envLaunch:   100 + int64(raw[6])%21,
		envPID:      10001 + int64(binary.LittleEndian.Uint16(raw[7:9]))%2000,
		message:     binary.LittleEndian.Uint32(raw[9:13]),
		medusaNonce: binary.LittleEndian.Uint32(raw[13:17]),
		packed:      binary.LittleEndian.Uint32(raw[17:21]),
	}
}

func hongguoAnonymousMedusaToken(nonce string) string {
	if len(nonce) == 25 && strings.HasPrefix(nonce, "A") {
		return nonce
	}
	if len(nonce) >= 24 {
		return "A" + nonce[:24]
	}
	return "A" + nonce + strings.Repeat("A", 24-len(nonce))
}

// hongguoAnonymousMedusa: the enhanced Medusa envelope for the anonymous
// playback route. Field-for-field port of upstream anonymous_medusa.
func hongguoAnonymousMedusa(queryHash [32]byte, bodyMD5 [16]byte, ts uint32, nowMS int64, identity hongguoAnonV5Identity, state hongguoV5ProcessState, entropy hongguoAnonEntropy) (string, error) {
	flags := [8]byte{0x44, 0x80, 0, 0, 0, 0, 0, 0}
	const anonEnv13 = -2
	const anonEnv14 = 200
	nestedPairs := [][2]int64{{1, 305}, {2, 4}, {3, 694367}, {5, 1621072674}}

	appID := "8662"
	license := "646637794"
	f13 := hongguoV5HashF13(queryHash, bodyMD5, ts)
	secToken := hongguoAnonymousMedusaToken(state.nonce)

	device := hongguoV5Proto([]hongguoV5Field{
		hongguoV5SintField(1, 1),
		hongguoV5SintField(2, 2),
		hongguoV5StringField(3, appID),
		hongguoV5StringField(4, identity.DeviceID),
		hongguoV5StringField(5, secToken),
		hongguoV5StringField(6, "!noperm!"),
		hongguoV5SintField(7, -888888),
		hongguoV5SintField(8, -888888),
		hongguoV5SintField(9, 3),
		hongguoV5SintField(10, -888888),
		hongguoV5StringField(11, "!notset!"),
		hongguoV5StringField(12, "Asia/Shanghai,8"),
		hongguoV5StringField(13, "zh_CN"),
		hongguoV5SintField(14, 4),
		hongguoV5FloatField(16, 0),
		hongguoV5FloatField(17, 0),
		hongguoV5FloatField(18, 0),
		hongguoV5FloatField(19, 0),
		hongguoV5FloatField(20, 0),
		hongguoV5FloatField(21, 0),
		hongguoV5StringField(22, hongguoV5OSVersion),
		hongguoV5SintField(23, 41),
		hongguoV5SintField(24, 36),
		hongguoV5SintField(25, state.startedMS),
		hongguoV5SintField(26, state.startedMS),
		hongguoV5SintField(27, state.startedMS),
		hongguoV5SintField(28, nowMS),
		hongguoV5SintField(29, -1),
		hongguoV5StringField(30, hongguoV5DeviceType),
		hongguoV5StringField(31, hongguoV5DeviceBrand),
		hongguoV5StringField(32, hongguoV5DeviceType),
		hongguoV5StringField(33, hongguoV5DeviceType),
		hongguoV5StringField(34, hongguoV5DeviceBrand),
		hongguoV5StringField(35, hongguoV5DeviceBrand),
		hongguoV5StringField(36, hongguoV5DeviceBrand),
		hongguoV5SintField(38, 31),
	})

	env13 := hongguoV5Proto([]hongguoV5Field{
		hongguoV5SintField(1, int64(ts)),
		hongguoV5SintField(2, anonEnv13),
		hongguoV5SintField(4, anonEnv14),
	})
	environment := hongguoV5Proto([]hongguoV5Field{
		hongguoV5SintField(1, entropy.envLaunch),
		hongguoV5SintField(2, 247235599),
		hongguoV5SintField(3, 247235596),
		hongguoV5SintField(5, 7),
		hongguoV5StringField(6, "v04.10.03.04-bugfix"),
		hongguoV5SintField(7, entropy.envPID),
		hongguoV5StringField(8, hongguoV5Channel),
		hongguoV5BytesField(12, device),
		hongguoV5BytesField(13, env13),
		hongguoV5StringField(14, hongguoV5VersionName),
	})
	var nestedFields []hongguoV5Field
	for _, pair := range nestedPairs {
		nestedFields = append(nestedFields, hongguoV5SintField(uint32(pair[0]), pair[1]))
	}
	nested := hongguoV5Proto(nestedFields)

	message := hongguoV5Proto([]hongguoV5Field{
		hongguoV5BytesField(1, hongguoV5Magic[:]),
		hongguoV5SintField(2, 5),
		hongguoV5SintField(3, int64(entropy.message)),
		hongguoV5StringField(4, appID),
		hongguoV5StringField(5, identity.DeviceID),
		hongguoV5StringField(6, license),
		hongguoV5StringField(7, hongguoV5VersionName),
		hongguoV5StringField(8, "v04.10.03-ml-android"),
		hongguoV5SintField(9, 0x040a0300),
		hongguoV5BytesField(10, flags[:]),
		hongguoV5SintField(12, int64(ts)),
		hongguoV5BytesField(13, f13[:]),
		hongguoV5BytesField(14, queryHash[:6]),
		hongguoV5BytesField(15, nested),
		hongguoV5StringField(16, secToken),
		hongguoV5SintField(17, int64(ts)),
		hongguoV5StringField(20, "none"),
		hongguoV5SintField(21, 312),
		hongguoV5BytesField(23, environment),
		hongguoV5StringField(24, `{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}`),
	})
	if len(message) < 4 {
		return "", errors.New("V5 medusa message is too short")
	}

	seedInput := make([]byte, 0, 68)
	seedInput = append(seedInput, hongguoV5SignKey[:]...)
	nonceBytes := hongguoV5LE32(entropy.medusaNonce)
	seedInput = append(seedInput, nonceBytes[:]...)
	seedInput = append(seedInput, hongguoV5SignKey[:]...)
	seedHash := hongguoSM3(seedInput)

	high := (entropy.medusaNonce >> 16) & 0xff
	seedWord := (high<<11 | (entropy.medusaNonce >> 24)) ^ (high >> 5) ^ high
	seed := hongguoV5LE32(^seedWord)

	transformed := append(append([]byte(nil), flags[:]...), hongguoV5XMXOR(message, seedHash[:])...)
	for left, right := 0, len(transformed)-1; left < right; left, right = left+1, right-1 {
		transformed[left], transformed[right] = transformed[right], transformed[left]
	}
	for index := range transformed {
		transformed[index] ^= seed[3-(index&3)]
	}

	check := uint32(0x18000001) | ((uint32(queryHash[0]) & 63) << 14) | ((uint32(f13[0]) & 63) << 8)
	packed := make([]byte, 0, 11+len(transformed))
	packed = append(packed, 0xca)
	packedEntropy := hongguoV5LE32(entropy.packed)
	packed = append(packed, packedEntropy[:]...)
	checkBytes := hongguoV5LE32(check)
	packed = append(packed, checkBytes[:]...)
	packed = append(packed, transformed...)
	packed = append(packed, byte(entropy.medusaNonce>>16), byte(entropy.medusaNonce>>24))

	key := hongguoV5MD5(hongguoV5SignKey[:16])
	iv := hongguoV5MD5(hongguoV5SignKey[16:])
	encrypted, err := hongguoV5NewAES(key, ts).encrypt(packed, iv)
	if err != nil {
		return "", err
	}

	prefix := hongguoV5LE32(5)
	prefixBytes := append(append([]byte(nil), prefix[:]...), hongguoV5Magic[:]...)
	timestamp := hongguoV5LE32(ts)
	for index := range prefixBytes {
		prefixBytes[index] ^= timestamp[index&3]
	}

	output := append([]byte(nil), prefixBytes...)
	output = append(output, byte(entropy.medusaNonce), byte(entropy.medusaNonce>>8), 0, 1)
	output = append(output, encrypted...)
	return base64.StdEncoding.EncodeToString(output), nil
}

// hongguoAnonymousPlaybackQuery: the ordered query envelope used by the
// anonymous enhanced V5 route. _rticket keeps its early position; the
// signing loop only changes its value. klink_egdi rides last, only when the
// registered identity returned one.
func hongguoAnonymousPlaybackQuery(identity hongguoAnonV5Identity, ticket int64) string {
	pairs := [][2]string{
		{"device_platform", "android"},
		{"os", "android"},
		{"ssmix", "a"},
		{"_rticket", fmt.Sprintf("%d", ticket)},
		{"cdid", identity.CDID},
		{"channel", hongguoV5Channel},
		{"aid", "8662"},
		{"app_name", "novelread"},
		{"version_code", hongguoV5VersionCode},
		{"version_name", hongguoV5VersionName},
		{"manifest_version_code", hongguoV5VersionCode},
		{"update_version_code", hongguoV5VersionCode},
		{"resolution", hongguoAnonResolution},
		{"dpi", hongguoAnonDPI},
		{"device_type", hongguoV5DeviceType},
		{"device_brand", hongguoV5DeviceBrand},
		{"language", "zh"},
		{"os_api", hongguoV5OSAPI},
		{"os_version", hongguoV5OSVersion},
		{"ac", "wifi"},
		{"host_abi", "arm64-v8a"},
		{"dragon_device_type", "phone"},
		{"pv_player", hongguoV5VersionCode},
		{"compliance_status", "0"},
		{"need_personal_recommend", "1"},
		{"player_so_load", "1"},
		{"is_android_pad_screen", "0"},
		{"rom_version", hongguoAnonROMVersion},
		{"iid", identity.InstallID},
		{"device_id", identity.DeviceID},
	}
	if identity.EGDI != "" {
		pairs = append(pairs, [2]string{"klink_egdi", identity.EGDI})
	}
	var query strings.Builder
	for _, pair := range pairs {
		if query.Len() > 0 {
			query.WriteByte('&')
		}
		query.WriteString(hongguoV5EncodeComponent(pair[0]))
		query.WriteByte('=')
		query.WriteString(hongguoV5EncodeComponent(pair[1]))
	}
	return query.String()
}

// hongguoAnonSignPlayback signs the enhanced anonymous playback POST.
// The caller supplies the exact gzip bytes that will be sent.
func hongguoAnonSignPlayback(base string, compressedBody []byte, identity hongguoAnonV5Identity) (hongguoV5Request, error) {
	nowMS := time.Now().UnixMilli()
	return hongguoAnonSignPlaybackAt(base, compressedBody, identity, nowMS, hongguoV5LoadProcessState(nowMS), hongguoAnonRandomEntropy())
}

// hongguoAnonSignPlaybackAt is the deterministic seam for tests.
func hongguoAnonSignPlaybackAt(base string, compressedBody []byte, identity hongguoAnonV5Identity, nowMS int64, state hongguoV5ProcessState, entropy hongguoAnonEntropy) (hongguoV5Request, error) {
	if base == "" {
		return hongguoV5Request{}, errors.New("anonymous V5 playback base URL is empty")
	}
	if strings.ContainsAny(base, "?#") {
		return hongguoV5Request{}, errors.New("anonymous V5 playback base URL must not contain a query or fragment")
	}
	if identity.DeviceID == "" || identity.InstallID == "" || identity.CDID == "" {
		return hongguoV5Request{}, errors.New("anonymous V5 playback identity is incomplete")
	}
	seconds := nowMS / 1000
	if seconds < 0 || seconds > math.MaxUint32 {
		return hongguoV5Request{}, errors.New("anonymous V5 timestamp is outside the protocol range")
	}
	ts := uint32(seconds)
	bodyMD5 := hongguoV5MD5(compressedBody)

	for offset := int64(0); offset < 1024; offset++ {
		ticket := nowMS + offset
		if ticket < nowMS {
			return hongguoV5Request{}, errors.New("anonymous V5 request ticket overflow")
		}
		query := hongguoAnonymousPlaybackQuery(identity, ticket)
		queryHash := hongguoSM3([]byte(query))
		if hongguoV5BranchIV(queryHash, bodyMD5, ts)&15 != 12 {
			continue
		}
		medusa, err := hongguoAnonymousMedusa(queryHash, bodyMD5, ts, nowMS, identity, state, entropy)
		if err != nil {
			return hongguoV5Request{}, err
		}
		argusBytes := hongguoV5LE32(ts)
		var ladonBytes [4]byte
		binary.BigEndian.PutUint32(ladonBytes[:], ts)
		headers := http.Header{
			"X-Khronos":        {fmt.Sprintf("%d", ts)},
			"X-Gorgon":         {hongguoV5GenerateGorgon(query, compressedBody, ts, entropy.gorgon)},
			"X-Argus":          {base64.StdEncoding.EncodeToString(argusBytes[:])},
			"X-Ladon":          {base64.StdEncoding.EncodeToString(ladonBytes[:])},
			"X-Helios":         {hongguoV5Helios(ts, entropy.helios)},
			"X-Medusa":         {medusa},
			"X-Xs-From-Web":    {"0"},
			"X-Ss-Stub":        {strings.ToUpper(hex.EncodeToString(bodyMD5[:]))},
			"Content-Type":     {"application/json; charset=utf-8"},
			"Content-Encoding": {"gzip"},
			"User-Agent":       {hongguoV5UserAgent},
			"Accept":           {"application/json"},
		}
		return hongguoV5Request{URL: base + "?" + query, Headers: headers}, nil
	}
	return hongguoV5Request{}, errors.New("anonymous V5 playback signing could not find the branch-12 ticket")
}
