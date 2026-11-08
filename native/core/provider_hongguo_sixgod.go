package core

import (
	"crypto/md5"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"math/bits"
	"strconv"
)

var errSixGodBranch = errors.New("sixgod: unknown branch")

func sixGodU32LE(v uint32) []byte {
	out := make([]byte, 4)
	binary.LittleEndian.PutUint32(out, v)
	return out
}

func sixGodU32BE(v uint32) []byte {
	out := make([]byte, 4)
	binary.BigEndian.PutUint32(out, v)
	return out
}

func sixGodByteAt(data []byte, index int) byte {
	if index < 0 || index >= len(data) {
		return 0
	}
	return data[index]
}

func sixGodU32LEAt(data []byte, offset int) uint32 {
	return uint32(sixGodByteAt(data, offset)) |
		uint32(sixGodByteAt(data, offset+1))<<8 |
		uint32(sixGodByteAt(data, offset+2))<<16 |
		uint32(sixGodByteAt(data, offset+3))<<24
}

func sixGodU32BEAt(data []byte, offset int) uint32 {
	return uint32(sixGodByteAt(data, offset))<<24 |
		uint32(sixGodByteAt(data, offset+1))<<16 |
		uint32(sixGodByteAt(data, offset+2))<<8 |
		uint32(sixGodByteAt(data, offset+3))
}

func sixGodU64LEAt(data []byte, offset int) uint64 {
	return uint64(sixGodU32LEAt(data, offset)) | uint64(sixGodU32LEAt(data, offset+4))<<32
}

func sixGodMD5(data []byte) []byte {
	sum := md5.Sum(data)
	return sum[:]
}

func sixGodMD5HexLower(data []byte) string {
	return hex.EncodeToString(sixGodMD5(data))
}

func sixGodB64(data []byte) string {
	return base64.StdEncoding.EncodeToString(data)
}

func sixGodRL8(x byte, k int) byte {
	s := k & 7
	if s == 0 {
		return x
	}
	return byte((uint16(x)<<uint(s) | uint16(x)>>uint(8-s)) & 0xff)
}

func sixGodROR32(v uint32, count int) uint32 {
	c := count % 32
	if c == 0 {
		return v
	}
	return (v >> uint(c)) | (v << uint(32-c))
}

func sixGodROL32(v uint32, shift int) uint32 {
	s := shift % 32
	if s == 0 {
		return v
	}
	return (v << uint(s)) | (v >> uint(32-s))
}

func sixGodROR64(v uint64, count int) uint64 {
	c := count % 64
	if c == 0 {
		return v
	}
	return (v >> uint(c)) | (v << uint(64-c))
}

func sixGodSumMd5(data []byte) uint32 {
	check := uint32(0x20220420)
	for i := 0; i < 12; i++ {
		var temp uint32
		if i%2 == 0 {
			temp = (check >> 3) ^ check
			check = uint32(sixGodByteAt(data, i)) ^ (check << 7)
		} else {
			temp = (check >> 5) ^ check
			check = uint32(sixGodByteAt(data, i)) | (check << 11)
			check = ^check
		}
		check = (check ^ temp) & 0xffffffff
	}
	check = check | 4
	check = check ^ 0x1000000
	return check
}

func sixGodBlockDivide(block []byte, chunks int) []uint32 {
	size := len(block) / chunks
	out := make([]uint32, 0, chunks)
	for i := 0; i < chunks; i++ {
		out = append(out, sixGodU32LEAt(block, i*size))
	}
	return out
}

func sixGodFF(a, b, c, d, m, s, t uint32) uint32 {
	return b + bits.RotateLeft32(a+((b&c)|(^b&d))+m+t, int(s))
}

func sixGodGG(a, b, c, d, m, s, t uint32) uint32 {
	return b + bits.RotateLeft32(a+((b&d)|(c&^d))+m+t, int(s))
}

func sixGodHH(a, b, c, d, m, s, t uint32) uint32 {
	return b + bits.RotateLeft32(a+(b^c^d)+m+t, int(s))
}

func sixGodII(a, b, c, d, m, s, t uint32) uint32 {
	return b + bits.RotateLeft32(a+(c^(b|(^d)))+m+t, int(s))
}

func sixGodMD5SumV3(msg []byte, countV2 uint32, orders []uint32, countV1 int) []byte {
	count := int(countV2 & 255)
	sv := make([]uint32, 0, 64)
	for i := 0; i < 64; i++ {
		sv = append(sv, sixGodROR32(sixGodSV2[i], countV1))
	}
	start := []uint32{
		sixGodROR32(0x79e0f2fb, count),
		sixGodROR32(0xc8b52570, count),
		sixGodROR32(0xebc2f8cd, count),
		sixGodROR32(0x7c104d93, count),
	}
	endCount := int((countV2 + 6) & 255)
	end := []uint32{
		sixGodROR32(0x19be4866, endCount),
		sixGodROR32(0xe85986b4, endCount),
		sixGodROR32(0xe19b326e, endCount),
		sixGodROR32(0x71d1d7d4, endCount),
	}
	a, bv, c, d := start[0], start[1], start[2], start[3]
	state := []uint32{a, bv, c, d}
	block := msg
	if len(block) > 64 {
		block = block[:64]
	}
	m := sixGodBlockDivide(block, 16)
	orderArr := [][]uint32{orders[0:16], orders[16:32], orders[32:48], orders[48:64]}
	shiftArr := [][]uint32{{7, 12, 17, 22}, {5, 9, 14, 20}, {4, 11, 16, 23}, {6, 10, 15, 21}}
	funcArr := []func(a, b, c, d, m, s, t uint32) uint32{sixGodFF, sixGodGG, sixGodHH, sixGodII}
	targetSeq := []int{0, 3, 2, 1}
	for fg := 0; fg < 4; fg++ {
		for k := 0; k < 16; k++ {
			t := targetSeq[k%4]
			args := []uint32{state[t], state[(t+1)%4], state[(t+2)%4], state[(t+3)%4]}
			state[t] = funcArr[fg](args[0], args[1], args[2], args[3], m[orderArr[fg][k]], shiftArr[fg][k%4], sv[fg*16+k])
		}
	}
	af := (a + state[0]) ^ end[0]
	bf := (bv + state[1]) ^ end[1]
	cf := (c + state[2]) ^ end[2]
	df := (d + state[3]) ^ end[3]
	result := append(append(append([]byte{}, sixGodU32LE(af)...), sixGodU32LE(bf)...), sixGodU32LE(cf)...)
	result = append(result, sixGodU32LE(df)...)
	s := sixGodSumMd5(result)
	result = append(result, sixGodU32LE(s)...)
	return result
}

func sixGodGetIv(iv uint32, data []byte) uint32 {
	for i := 0; i < len(data); i++ {
		if i%2 == 0 {
			iv = (iv >> 4) ^ iv ^ (iv << 6) ^ uint32(data[i])
		} else {
			inner := (iv >> 7) ^ iv ^ (uint32(data[i]) | (iv << 12))
			iv = ^inner
		}
		iv = iv & 0xffffffff
	}
	return iv
}

func sixGodBXOR(a, b []byte) []byte {
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

func sixGodBranch0Xor(data []uint32, base uint32, di []uint32, tt03 []uint32, round int, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10 int) []uint32 {
	d := append([]uint32(nil), data...)
	for i := 0; i < round; i++ {
		offset := base + uint32(i)
		n0 := di[offset&127]
		n1 := ((d[x3] ^ d[x4]) & d[x1]) ^ d[x3]
		n2 := sixGodROL32(d[x1], 26) ^ sixGodROL32(d[x1], 21) ^ sixGodROL32(d[x1], 7)
		offset = offset & 63
		n3 := tt03[offset]
		n4 := n0 + n1 + n2 + n3 + d[x5]
		n5 := sixGodROL32(d[x2], 30) ^ sixGodROL32(d[x2], 19) ^ sixGodROL32(d[x2], 10)
		n6 := (d[x2] & d[x6]) | ((d[x2] | d[x6]) & d[x7])
		n7 := n5 + n6
		o := d[x9]
		nd := []uint32{d[7], d[0], d[1], d[2], d[3], d[4], d[5], d[6]}
		d = nd
		d[x10] = n7 + n4
		d[x8] = o + n4
	}
	return d
}

func sixGodBranch0(ivV0 int, khronos uint32, querySm3, bodyMd5Bytes, tsBytes []byte) []byte {
	tt01 := []uint32{0xc4a78580, 0xb3c0fd39, 0xc58c5686, 0xc9aa3ba7, 0xf5a7adf2, 0x963c2ed1}
	ivV1 := tt01[ivV0]
	countV1 := (ivV1 + khronos + 1) & 255
	countV2 := ivV1 + khronos
	tt02 := []uint32{
		0xebb64faf, 0x07aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8,
		0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288,
		0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00, 0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e,
		0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83, 0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c,
		0x617ce2a6, 0xe423417e, 0x0a40e143, 0x544e4032, 0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x05b23bb3,
		0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8,
		0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14,
		0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1, 0x6ca86f6e, 0x00284ba7, 0x08387cfa, 0x5fb37586,
	}
	tt03 := make([]uint32, 64)
	for i := 0; i < 64; i++ {
		tt03[i] = sixGodROR32(tt02[i], int(countV1))
	}
	n0 := (countV2 + 2) & 7
	pad := make([]byte, 4)
	seed := []byte{0xfa, 0x45, 0x61, 0xd7}
	for i := 0; i < 4; i++ {
		v := int(seed[i]) | (int(seed[i]) << 8)
		v = v >> int(n0)
		pad[i] = byte(v & 255)
	}
	countV2 = countV2 & 255
	rorC := func(x uint32) uint32 { return sixGodROR32(x, int(countV2)) }
	initValue := []uint32{rorC(0x7aba4fc8), rorC(0x67166507), rorC(0x6403fa00), rorC(0x340f512f), rorC(984304912), rorC(3005047866), rorC(2874125293), rorC(2152413264)}
	data := append(append(append([]byte{}, querySm3...), bodyMd5Bytes...), tsBytes...)
	data = append(data, pad...)
	data = append(data, 0, 0, 0, 0, 0, 0, 1, 0xa0)
	di := make([]uint32, 0, 128)
	for i := 0; i < len(data)/4; i++ {
		di = append(di, sixGodU32BEAt(data, i*4))
	}
	di0 := di[0]
	for i := 0; i < 112; i++ {
		di1 := di[i+1]
		di14 := di[i+14]
		rDi1 := sixGodROL32(di1, 14) ^ sixGodROL32(di1, 25) ^ (di1 >> 3)
		rDi2 := sixGodROL32(di14, 13) ^ sixGodROL32(di14, 15) ^ (di14 >> 10)
		di0 = di0 + di[i+9] + rDi1 + rDi2
		di = append(di, di0)
		di0 = di1
	}
	var vj []uint32
	switch ivV0 {
	case 5:
		vj = sixGodBranch0Xor(initValue, ivV1, di, tt03, 100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5)
	case 4:
		vj = sixGodBranch0Xor(initValue, ivV1, di, tt03, 96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4)
	case 3:
		vj = sixGodBranch0Xor(initValue, ivV1, di, tt03, 99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6)
	case 2:
		vj = sixGodBranch0Xor(initValue, ivV1, di, tt03, 96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5)
	case 1:
		vj = sixGodBranch0Xor(initValue, ivV1, di, tt03, 96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4)
	default:
		vj = sixGodBranch0Xor(initValue, ivV1, di, tt03, 101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3)
	}
	ret := make([]byte, 0, 32)
	for i := 0; i < 8; i++ {
		vv := vj[i] + initValue[i]
		ret = append(ret, sixGodU32BE(vv)...)
	}
	ret = sixGodBXOR(ret[:16], ret[16:])
	s := sixGodSumMd5(ret)
	ret = append(ret, sixGodU32LE(s)...)
	return ret
}

func sixGodBranch1TableF(ivV0 int) func(int) uint64 {
	table := sixGodBranchOne[ivV0*16384:]
	return func(x int) uint64 {
		return sixGodU64LEAt(table, x)
	}
}

func sixGodR00(r0, r1, r2, r3, r4, r5, r6, r7 uint64, tt uint64, tableF func(int) uint64) uint64 {
	x := tableF(int(r0>>56) * 8)
	r1 = (r1 >> 45) & 2040
	if tt > 0 {
		x = x ^ tt
	}
	x = x ^ tableF(int(r1)+2048)
	r2 = (r2 >> 37) & 2040
	x = x ^ tableF(int(r2)+4096)
	r3 = (r3 >> 29) & 2040
	x = x ^ tableF(int(r3)+6144)
	r4 = (r4 >> 21) & 2040
	x = x ^ tableF(int(r4)+8192)
	r5 = (r5 >> 13) & 2040
	x = x ^ tableF(int(r5)+10240)
	r6 = (r6 >> 8) & 255
	x = x ^ tableF(int(r6)*8+12288)
	r7 = r7 & 255
	x = x ^ tableF(int(r7)*8+14336)
	return x
}

func sixGodSwapV0(src, srcXor []uint64, tt2 []uint64, tableF func(int) uint64, order1 []byte, typ []uint64) []uint64 {
	da0 := make([]uint64, 8)
	ha0 := append([]uint64(nil), srcXor...)
	for i := 0; i < 8; i++ {
		da0[i] = src[order1[i]] ^ srcXor[i]
	}
	for round := 0; round < 10; round++ {
		rr0 := sixGodR00(ha0[0], ha0[1], ha0[2], ha0[3], ha0[4], ha0[5], ha0[6], ha0[7], 0, tableF)
		rr1 := sixGodR00(ha0[1], ha0[2], ha0[3], ha0[4], ha0[5], ha0[6], ha0[7], ha0[0], 0, tableF)
		rr2 := sixGodR00(ha0[2], ha0[3], ha0[4], ha0[5], ha0[6], ha0[7], ha0[0], ha0[1], 0, tableF)
		rr3 := sixGodR00(ha0[3], ha0[4], ha0[5], ha0[6], ha0[7], ha0[0], ha0[1], ha0[2], 0, tableF)
		rr4 := sixGodR00(ha0[4], ha0[5], ha0[6], ha0[7], ha0[0], ha0[1], ha0[2], ha0[3], 0, tableF)
		rr5 := sixGodR00(ha0[5], ha0[6], ha0[7], ha0[0], ha0[1], ha0[2], ha0[3], ha0[4], 0, tableF)
		rr6 := sixGodR00(ha0[6], ha0[7], ha0[0], ha0[1], ha0[2], ha0[3], ha0[4], ha0[5], 0, tableF)
		rr7 := sixGodR00(ha0[7], ha0[0], ha0[1], ha0[2], ha0[3], ha0[4], ha0[5], ha0[6], 0, tableF)
		rr7 = rr7 ^ tt2[round+1]
		d0, d1, d2, d3, d4, d5, d6, d7 := da0[0], da0[1], da0[2], da0[3], da0[4], da0[5], da0[6], da0[7]
		da0[0] = sixGodR00(d0, d1, d2, d3, d4, d5, d6, d7, rr0, tableF)
		da0[1] = sixGodR00(d1, d2, d3, d4, d5, d6, d7, d0, rr1, tableF)
		da0[2] = sixGodR00(d2, d3, d4, d5, d6, d7, d0, d1, rr2, tableF)
		da0[3] = sixGodR00(d3, d4, d5, d6, d7, d0, d1, d2, rr3, tableF)
		da0[4] = sixGodR00(d4, d5, d6, d7, d0, d1, d2, d3, rr4, tableF)
		da0[5] = sixGodR00(d5, d6, d7, d0, d1, d2, d3, d4, rr5, tableF)
		da0[6] = sixGodR00(d6, d7, d0, d1, d2, d3, d4, d5, rr6, tableF)
		da0[7] = sixGodR00(d7, d0, d1, d2, d3, d4, d5, d6, rr7, tableF)
		ha0 = []uint64{rr0, rr1, rr2, rr3, rr4, rr5, rr6, rr7}
	}
	if typ == nil {
		src[0] = da0[0] ^ srcXor[0] ^ src[0]
		src[1] = da0[7] ^ srcXor[1] ^ src[1]
		src[2] = da0[6] ^ srcXor[2] ^ src[2]
		src[3] = da0[5] ^ srcXor[3] ^ src[3]
		src[4] = da0[4] ^ srcXor[4] ^ src[4]
		src[5] = da0[3] ^ srcXor[5] ^ src[5]
		src[6] = da0[2] ^ srcXor[6] ^ src[6]
		src[7] = da0[1] ^ srcXor[7] ^ src[7]
	} else {
		src[0] = da0[7] ^ typ[1]
		src[1] = da0[6] ^ typ[2]
		src[2] = da0[5] ^ typ[3]
		src[3] = da0[4] ^ typ[4]
		src[4] = da0[3] ^ typ[5]
		src[5] = da0[2] ^ typ[6]
		src[6] = da0[1] ^ typ[7] ^ src[7]
		src[7] = da0[0] ^ typ[0]
	}
	return src
}

func sixGodBranch1(ivV0 int, khronos uint32, querySm3, bodyMd5Bytes, tsBytes []byte) []byte {
	tt1a := []uint32{0x808a9c79, 0xf079807e, 0xbadf79c5, 0xa785d3ff, 0x82d8438c}
	ivV1 := tt1a[ivV0]
	cV1raw := (ivV1 + khronos) & 255
	cV1 := sixGodROR64(uint64(khronos), int(cV1raw))
	orders := sixGodHexBytes("050701020400060300050204010307060507020401060300030002040607010504050003060201070000000000000000")
	order1 := orders[ivV0*8 : ivV0*8+8]
	ivV1b := (ivV1 + khronos + 1) & 63
	tt1b := []uint64{0x87aeea5dab37cd6b, 0x7ff48becb4f54087, 0xb0724c06706bbd5d, 0x1fe5dfb1143e328d, 0x1a2331d00af4f1f2, 0xcaff7131bb1e71ba, 0x33385e1042752218, 0xff01ed65d4a441fb, 0xadb1ec8828c80e8, 0x62475d12f4e06fe7, 0xbd0b238da4fe72}
	tt2 := make([]uint64, 11)
	for i := 0; i < 11; i++ {
		tt2[i] = sixGodROR64(tt1b[i], int(ivV1b))
	}
	toSign := append(append(append([]byte{}, querySm3...), bodyMd5Bytes...), tsBytes...)
	toSign = append(toSign, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	src := make([]uint64, 0, 8)
	for i := 0; i < len(toSign)/8; i++ {
		var v uint64
		for j := 0; j < 8; j++ {
			v = (v << 8) | uint64(toSign[i*8+j])
		}
		src = append(src, v)
	}
	srcXor := []uint64{cV1, cV1, cV1, cV1, cV1, cV1, cV1, cV1}
	tableF := sixGodBranch1TableF(ivV0)
	swap := sixGodSwapV0(src, srcXor, tt2, tableF, order1, nil)
	data := []uint64{0, 0, 0, 0, 0, 0, 0, 416}
	srcXor2 := []uint64{swap[4], swap[3], swap[2], swap[1], swap[0], swap[7], swap[6], swap[5]}
	swap = sixGodSwapV0(data, srcXor2, tt2, tableF, order1, swap)
	ret := make([]byte, 0, 32)
	for i := 7; i >= 0; i-- {
		vv := swap[i]
		pp := make([]byte, 8)
		for j := 0; j < 8; j++ {
			pp[j] = byte((vv >> uint(j*8)) & 255)
		}
		ret = append(ret, pp[1], pp[3], pp[5], pp[6])
	}
	for i := 0; i < 16; i++ {
		ret[i] ^= ret[i+16]
	}
	ret = ret[:16]
	s := sixGodSumMd5(ret)
	ret = append(ret, sixGodU32LE(s)...)
	return ret
}

func sixGodBranch2(iv uint32, khronos uint32, querySm3, bodyMd5Bytes, tsBytes []byte) []byte {
	n0 := (iv & 13) * 86
	ivV0 := ((n0 >> 15) & 255) + ((n0 >> 8) & 255)
	t001 := []uint32{0x8980f29b, 0xeb549c7f, 0xb08726db, 0xd40cb5e6, 0xe8f559e4}
	n1 := t001[ivV0]
	countV1 := (n1 + khronos + 1) & 255
	countV2 := n1 + khronos
	n0b := (countV2 + 5) & 7
	pad := make([]byte, 0, 8)
	seed := []byte{0x84, 0x96, 0x77, 0x9d, 0xd4, 0x15, 0x0b, 0xf8}
	for i := 0; i < 8; i++ {
		v := int(seed[i]) | (int(seed[i]) << 8)
		v = v >> int(n0b)
		pad = append(pad, byte(v&255))
	}
	data := append(append(append([]byte{}, querySm3...), bodyMd5Bytes...), tsBytes...)
	data = append(data, pad...)
	data = append(data, 0xa0, 0x01, 0, 0)
	idx := int(ivV0) * 64
	return sixGodMD5SumV3(data, countV2, sixGodB2Orders[idx:idx+64], int(countV1))
}

func sixGodHashF13(querySm3, bodyMd5Bytes, tsBytes []byte, khronos uint32) ([]byte, error) {
	iv := sixGodGetIv(0x20230928, querySm3)
	iv = sixGodGetIv(iv, bodyMd5Bytes)
	iv = sixGodGetIv(iv, tsBytes)
	ivV0 := ((iv & 15) * 171) >> 9
	branch := int(iv&15) - int((ivV0*3)&255)
	switch branch {
	case 0:
		return sixGodBranch0(int(ivV0), khronos, querySm3, bodyMd5Bytes, tsBytes), nil
	case 1:
		return sixGodBranch1(int(ivV0), khronos, querySm3, bodyMd5Bytes, tsBytes), nil
	case 2:
		return sixGodBranch2(iv, khronos, querySm3, bodyMd5Bytes, tsBytes), nil
	default:
		return nil, errSixGodBranch
	}
}

func sixGodHelios(khronos uint32, randValue uint32) string {
	value := randValue
	if value == 0 {
		var buf [4]byte
		if _, err := rand.Read(buf[:]); err == nil {
			value = binary.LittleEndian.Uint32(buf[:])
		}
		if value == 0 {
			value = 0x9e3779b9
		}
	}
	seed := append(sixGodU32LE(value), []byte("8662")...)
	digest := sixGodMD5(seed)
	hexChars := "0123456789abcdef"
	keys := make([]byte, 0, 32)
	for i := 0; i < len(digest); i++ {
		keys = append(keys, hexChars[(digest[i]>>4)&15], hexChars[digest[i]&15])
	}
	le64 := func(b []byte, o int) uint64 {
		return sixGodU64LEAt(b, o)
	}
	table := []uint64{le64(keys, 0)}
	words := []uint64{le64(keys, 0), le64(keys, 8), le64(keys, 16), le64(keys, 24)}
	first := words[0]
	second := words[1]
	words = words[2:]
	for idx := 0; idx < 0x22; idx++ {
		v2 := sixGodROR64(second, 8)
		v2 = v2 + first
		v2 = v2 ^ uint64(idx)
		words = append(words, v2)
		v2 = v2 ^ sixGodROR64(first, 61)
		table = append(table, v2)
		first = v2
		second = words[0]
		words = words[1:]
	}
	raw := []byte(strconv.FormatUint(uint64(khronos), 10) + "-1588093228-8662")
	pad := 16 - (len(raw) % 16)
	for i := 0; i < pad; i++ {
		raw = append(raw, byte(pad))
	}
	output := make([]byte, 0, len(raw))
	for off := 0; off < len(raw); off += 16 {
		left := le64(raw, off)
		right := le64(raw, off+8)
		for idx := 0; idx < 0x22; idx++ {
			right = table[idx] ^ (left + sixGodROR64(right, 8))
			left = right ^ sixGodROR64(left, 61)
		}
		output = append(output, sixGodU32LE(uint32(left&0xffffffff))...)
		output = append(output, sixGodU32LE(uint32((left>>32)&0xffffffff))...)
		output = append(output, sixGodU32LE(uint32(right&0xffffffff))...)
		output = append(output, sixGodU32LE(uint32((right>>32)&0xffffffff))...)
	}
	return sixGodB64(append(sixGodU32LE(value), output...))
}
