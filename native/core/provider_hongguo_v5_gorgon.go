package core

// The playback/enrollment x-gorgon variant.
//
// Go port of upstream fqapp sign/gorgon.rs generate_v5_gorgon (bef83c90),
// itself ported from Amor5207/lvguo-tv v2.0.8 web/internal/sign/sign.go::gorgon.
// Its KSA/PRGA intentionally differ from the legacy signer in
// provider_hongguo_player_sign.go: the KSA assigns table[index] = table[j]
// instead of swapping, and that quirk is part of the accepted wire output.
// Do not "fix" it.

import (
	"crypto/md5"
	"encoding/binary"
	"fmt"
	"math/bits"
	"strings"
)

// hongguoV5GenerateGorgon: the 8404 x-gorgon variant for the anonymous
// enhanced V5 door and the anonymous device registration.
func hongguoV5GenerateGorgon(query string, body []byte, ts uint32, nonce uint16) string {
	queryMD5 := md5.Sum([]byte(query))
	bodyMD5 := md5.Sum(body)
	data := make([]byte, 0, 20)
	data = append(data, queryMD5[:4]...)
	data = append(data, bodyMD5[:4]...)
	data = append(data, 0, 0, 0, 0)
	magicConstant := hongguoV5LE32(67503104)
	data = append(data, magicConstant[:]...)
	var tsBytes [4]byte
	binary.BigEndian.PutUint32(tsBytes[:], ts)
	data = append(data, tsBytes[:]...)

	key := [8]byte{0x4a, 0x40, 0x16, byte(nonce >> 8), 0x47, 0x6c, 1, byte(nonce)}
	var table [256]byte
	for index := range table {
		table[index] = byte(index)
	}
	j := 0
	for index := 0; index < 256; index++ {
		j = (j + int(table[index]) + int(key[index%8])) & 255
		table[index] = table[j]
	}

	j = 0
	for index := range data {
		j = (j + int(table[index+1])) & 255
		value := table[j]
		table[index+1] = value
		data[index] ^= table[(int(value)*2)&255]
	}

	// In-place mutation matters: the final iteration reads the already-written
	// first byte as its next value, exactly like the reference loop.
	for index := range data {
		value := bits.RotateLeft8(data[index], 4)
		var next byte
		if index+1 < len(data) {
			next = data[index+1]
		} else {
			next = data[0]
		}
		data[index] = ^(bits.Reverse8(next^value) ^ 20)
	}

	var out strings.Builder
	out.WriteString("8404")
	for _, b := range []byte{byte(nonce), byte(nonce >> 8), 0x40, 1} {
		fmt.Fprintf(&out, "%02x", b)
	}
	for _, b := range data {
		fmt.Fprintf(&out, "%02x", b)
	}
	return out.String()
}
