package core

import (
	"crypto/md5"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"math/bits"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

// 红果账号签名（对照 tree_104 的 provider_hongguo_signer.go 原样移植）。
// 魔蚁原有的 hongguoPrepareSignedRequest 与它不等价：原有路会往查询串里加 ts
// 参数、不发 sdk-version / x-xs-from-web、Argus 里带真实设备号；对照仓验通的
// 发码/验码路是这里的形态（不加 ts、带两个头、Argus 取查询串里的 device_id，
// 此时查询串已删 device_id/iid、即空，Medusa 才带真实设备号）。账号 passport
// 调用只走这里，不动取流用的 hongguoPrepareSignedRequest。

type hongguoSignOptionsKey struct{}

type hongguoSignerIdentity struct {
	DeviceID  string
	InstallID string
}

type hongguoSignOptions struct {
	Playback       bool
	PlayerOnly     bool
	Identity       hongguoSignerIdentity
	MedusaDeviceID string
}

func hongguoTicketBranch(query string, body []byte, ts uint32) int {
	queryHash := hongguoSM3([]byte(query))
	var bodyHash [16]byte
	if body != nil {
		bodyHash = md5.Sum(body)
	}
	iv := sixGodGetIv(0x20230928, queryHash[:])
	iv = sixGodGetIv(iv, bodyHash[:])
	iv = sixGodGetIv(iv, sixGodU32LE(ts))
	return int(iv&15) % 3
}

func hongguoPickTicket(query url.Values, body []byte, now time.Time) (int64, bool) {
	ts := uint32(now.Unix())
	base := now.UnixMilli()
	for offset := int64(0); offset < 128; offset++ {
		ticket := base + offset
		trial := url.Values{}
		for key, values := range query {
			trial[key] = append([]string(nil), values...)
		}
		trial.Set("_rticket", strconv.FormatInt(ticket, 10))
		if hongguoTicketBranch(trial.Encode(), body, ts) == 0 {
			return ticket, true
		}
	}
	return base, false
}

func hongguoSignRequest(request *http.Request, body []byte, now time.Time, opts hongguoSignOptions) {
	query := request.URL.Query()
	if opts.Identity.DeviceID != "" {
		query.Set("device_id", opts.Identity.DeviceID)
	}
	if opts.Identity.InstallID != "" {
		query.Set("iid", opts.Identity.InstallID)
	}
	ticket, _ := hongguoPickTicket(query, body, now)
	query.Set("_rticket", strconv.FormatInt(ticket, 10))
	request.URL.RawQuery = query.Encode()
	signHongguoPlayerRequestTicketMedusa(request, body, now, ticket, opts.PlayerOnly, sixGodMedusaOpts{DeviceID: opts.MedusaDeviceID})
	if opts.PlayerOnly {
		return
	}
	request.Header.Set("sdk-version", "2")
	request.Header.Set("x-xs-from-web", "0")
	if opts.Playback {
		return
	}
	request.Header.Set("x-tt-request-tag", "t=0;n=0")
	request.Header.Set("passport-sdk-version", "50561")
	if body != nil {
		request.Header.Set("x-vc-bdturing-sdk-version", "3.7.2.cn")
	}
}

func hongguoSignPlaybackRequest(request *http.Request, body []byte, now time.Time, identity hongguoSignerIdentity) {
	hongguoSignRequest(request, body, now, hongguoSignOptions{Playback: true, Identity: identity})
}

// signHongguoPlayerRequestTicketMedusa：对照 tree_104 的 provider_hongguo_player_sign.go
// 同名函数原样移植，落在这里而不改 player_sign.go（那是取流工人的文件）。
// 与魔蚁现有的 signHongguoPlayerRequestFull 的差别：minimal 为真时不发
// X-Gorgon / X-Helios / X-Medusa；Argus 的设备号取查询串里的 device_id。
func signHongguoPlayerRequestTicketMedusa(request *http.Request, body []byte, now time.Time, ticket int64, minimal bool, medusaOpts sixGodMedusaOpts) {
	stamp := uint32(now.Unix())
	queryHash := md5.Sum([]byte(request.URL.RawQuery))
	var payload [20]byte
	copy(payload[:4], queryHash[:4])
	if body != nil {
		bodyHash := md5.Sum(body)
		copy(payload[4:8], bodyHash[:4])
		request.Header.Set("X-SS-STUB", fmt.Sprintf("%X", bodyHash))
	}
	copy(payload[12:16], []byte{0, 6, 11, 28})
	binary.BigEndian.PutUint32(payload[16:], stamp)
	key := [...]byte{0x44, 0xb9, 0xb9, 0xd9, 0xa4, 0xae, 0xf9, 0xfc, 0xa4, 0x93, 0xaa, 0x75, 0x7c, 0xa3, 0xc2, 0xc4, 0xa4, 0x96, 0x93, 0x8f}
	for index := range payload {
		payload[index] ^= key[index]
	}
	for index := range payload {
		mixed := bits.RotateLeft8(payload[index], 4) ^ payload[(index+1)%len(payload)]
		payload[index] = bits.Reverse8(mixed) ^ 0xff ^ byte(len(payload))
	}
	signature := append([]byte{0x84, 0x04, 0x40, 0x1c, 0, 0}, payload[:]...)
	request.Header.Set("X-Khronos", strconv.FormatUint(uint64(stamp), 10))
	request.Header.Set("X-SS-Req-Ticket", strconv.FormatInt(ticket, 10))

	nonce, err := newHongguoPlayerNonce()
	if err != nil {
		return
	}
	request.Header.Set("X-Argus", hongguoPlayerArgus(request.URL.RawQuery, body, stamp, request.URL.Query().Get("device_id"), nonce))
	request.Header.Set("X-Ladon", hongguoPlayerLadon(request.URL.Query().Get("aid"), stamp, nonce[2:6]))
	if minimal {
		return
	}
	request.Header.Set("X-Gorgon", hex.EncodeToString(signature))
	request.Header.Set("X-Helios", sixGodHelios(stamp, 0))
	if medusa, err := sixGodGenMedusa(request.URL.String(), body, stamp, medusaOpts); err == nil {
		request.Header.Set("X-Medusa", medusa)
	}
}
