package core

// Playback door health and identity-rotation pacing.
//
// Go port of upstream fqapp upstream/playback_routes.rs (2f31ba83 + bef83c90),
// itself ported from N3urda/hongguoTV PlaybackRoutes.kt: every playback door
// keeps its own health entry, an empty HTTP 200 body parks that door for
// 30s, non-empty failures park it for 5s, and consecutive all-empty rounds
// eventually justify one anonymous-identity rotation.
//
// One deliberate adaptation: upstream keeps the state process-wide in a
// OnceLock; here it lives on the hongguoAppClient (one per Downloader), so
// tests get a fresh state per fixture and production keeps one state per
// core instance. The semantics (cooldowns, plan order, rotation pacing)
// are identical.

import (
	"sort"
	"sync"
	"time"
)

const (
	// hongguoPlaybackEmptyCooldown: an empty body parks a door long enough
	// that a retry loop cannot hammer it.
	hongguoPlaybackEmptyCooldown = 30 * time.Second
	// hongguoPlaybackErrorCooldown: a non-empty, non-auth failure parks it briefly.
	hongguoPlaybackErrorCooldown = 5 * time.Second
	// hongguoPlaybackRotateCooldownSettled: after a rotation that still
	// produced empty models, wait this long before rotating again.
	hongguoPlaybackRotateCooldownSettled = 30 * time.Second
	// hongguoPlaybackRotateCooldownFailed: after a rotation that could not
	// even register, retry sooner.
	hongguoPlaybackRotateCooldownFailed = 5 * time.Second
	// hongguoPlaybackEmptyRotateRounds: consecutive all-empty rounds before
	// a foreground request rotates identity.
	hongguoPlaybackEmptyRotateRounds = 2
)

var hongguoPlaybackRoutesStart = time.Now()

// hongguoPlaybackNowMS: monotonic milliseconds since this process started;
// never a wall clock.
func hongguoPlaybackNowMS() int64 {
	return time.Since(hongguoPlaybackRoutesStart).Milliseconds()
}

// hongguoPlaybackDoor: which upstream door a route addresses.
type hongguoPlaybackDoor int

const (
	hongguoPlaybackDoorAnon hongguoPlaybackDoor = iota
	hongguoPlaybackDoorV5
	hongguoPlaybackDoorVideoModel
	hongguoPlaybackDoorVideoTab
)

// hongguoPlaybackRoute: one independently-tracked playback route.
type hongguoPlaybackRoute struct {
	door      hongguoPlaybackDoor
	hostIndex uint8
}

const (
	hongguoV5PlayerHost    = "https://api5-normal-sinfonlinea.fqnovel.com"
	hongguoVideoTabHost    = "https://api5-normal-sinfonlineb.fqnovel.com"
	hongguoVideoModelHostA = "https://api5-normal-sinfonlinea.fqnovel.com"
	hongguoVideoModelHostC = "https://api5-normal-sinfonlinec.fqnovel.com"
)

var hongguoVideoModelHosts = []string{hongguoVideoModelHostA, hongguoVideoModelHostC}
var hongguoVideoTabHosts = []string{hongguoVideoTabHost}

func (route hongguoPlaybackRoute) host() string {
	switch route.door {
	case hongguoPlaybackDoorAnon, hongguoPlaybackDoorV5:
		return hongguoV5PlayerHost
	case hongguoPlaybackDoorVideoModel:
		if int(route.hostIndex) < len(hongguoVideoModelHosts) {
			return hongguoVideoModelHosts[route.hostIndex]
		}
		return hongguoVideoModelHosts[0]
	case hongguoPlaybackDoorVideoTab:
		if int(route.hostIndex) < len(hongguoVideoTabHosts) {
			return hongguoVideoTabHosts[route.hostIndex]
		}
		return hongguoVideoTabHosts[0]
	}
	return hongguoV5PlayerHost
}

// hongguoPlaybackRouteTag: short label for diagnostics; hosts themselves
// are never logged.
func (route hongguoPlaybackRoute) tag() string {
	switch route.door {
	case hongguoPlaybackDoorAnon:
		return "anon"
	case hongguoPlaybackDoorV5:
		return "v5"
	case hongguoPlaybackDoorVideoModel:
		if route.hostIndex == 1 {
			return "model-c"
		}
		return "model-a"
	case hongguoPlaybackDoorVideoTab:
		return "tab-b"
	}
	return "?"
}

// hongguoPlaybackRoutes: every route the playback chain may use, in
// preference order: anon -> v5 -> model-a -> model-c -> tab-b.
func hongguoPlaybackRoutes() []hongguoPlaybackRoute {
	all := []hongguoPlaybackRoute{
		{door: hongguoPlaybackDoorAnon, hostIndex: 0},
		{door: hongguoPlaybackDoorV5, hostIndex: 0},
	}
	for index := range hongguoVideoModelHosts {
		all = append(all, hongguoPlaybackRoute{door: hongguoPlaybackDoorVideoModel, hostIndex: uint8(index)})
	}
	for index := range hongguoVideoTabHosts {
		all = append(all, hongguoPlaybackRoute{door: hongguoPlaybackDoorVideoTab, hostIndex: uint8(index)})
	}
	return all
}

type hongguoPlaybackHealth struct {
	lastSuccessMS  int64
	hasSuccess     bool
	blockedUntilMS int64
	empty          bool
}

// hongguoPlaybackRouteState: playback health plus identity-rotation pacing.
type hongguoPlaybackRouteState struct {
	mu            sync.Mutex
	health        map[hongguoPlaybackRoute]hongguoPlaybackHealth
	emptyRounds   uint32
	lastRotateMS  int64
	hasRotated    bool
	rotateOK      bool
	hasRotateInfo bool
	rotations     uint32
}

func (state *hongguoPlaybackRouteState) healthFor(route hongguoPlaybackRoute) hongguoPlaybackHealth {
	if state.health == nil {
		return hongguoPlaybackHealth{}
	}
	return state.health[route]
}

// hongguoPlaybackPlan: healthy routes first, blocked ones skipped entirely.
// A speculative (prefetch) caller never probes a cooling route: background
// work must not spend the failure budget the foreground needs. A foreground
// caller with every door cooling gets all of them back, ordered by recovery
// time.
func (state *hongguoPlaybackRouteState) Plan(nowMS int64, speculative bool) []hongguoPlaybackRoute {
	state.mu.Lock()
	defer state.mu.Unlock()
	all := hongguoPlaybackRoutes()
	available := make([]hongguoPlaybackRoute, 0, len(all))
	for _, route := range all {
		if state.healthFor(route).blockedUntilMS <= nowMS {
			available = append(available, route)
		}
	}
	sort.SliceStable(available, func(i, j int) bool {
		a, b := state.healthFor(available[i]), state.healthFor(available[j])
		if a.hasSuccess != b.hasSuccess {
			return a.hasSuccess
		}
		return a.lastSuccessMS > b.lastSuccessMS
	})
	if speculative {
		if len(available) > 1 {
			available = available[:1]
		}
		return available
	}
	if len(available) == 0 {
		cooling := append([]hongguoPlaybackRoute(nil), all...)
		sort.SliceStable(cooling, func(i, j int) bool {
			return state.healthFor(cooling[i]).blockedUntilMS < state.healthFor(cooling[j]).blockedUntilMS
		})
		return cooling
	}
	return available
}

// hongguoPlaybackParked: true while this door is parked by a cooldown.
func (state *hongguoPlaybackRouteState) Parked(route hongguoPlaybackRoute, nowMS int64) bool {
	state.mu.Lock()
	defer state.mu.Unlock()
	return state.healthFor(route).blockedUntilMS > nowMS
}

// hongguoPlaybackExhausted: every route is parked because of an empty body.
func (state *hongguoPlaybackRouteState) Exhausted(nowMS int64) bool {
	state.mu.Lock()
	defer state.mu.Unlock()
	for _, route := range hongguoPlaybackRoutes() {
		health := state.healthFor(route)
		if !health.empty || health.blockedUntilMS <= nowMS {
			return false
		}
	}
	return true
}

func (state *hongguoPlaybackRouteState) Success(route hongguoPlaybackRoute, nowMS int64) {
	state.mu.Lock()
	defer state.mu.Unlock()
	if state.health == nil {
		state.health = make(map[hongguoPlaybackRoute]hongguoPlaybackHealth)
	}
	health := state.health[route]
	health.lastSuccessMS = nowMS
	health.hasSuccess = true
	health.blockedUntilMS = 0
	health.empty = false
	state.health[route] = health
}

func (state *hongguoPlaybackRouteState) Failed(route hongguoPlaybackRoute, nowMS int64, empty bool) {
	state.mu.Lock()
	defer state.mu.Unlock()
	cooldown := hongguoPlaybackErrorCooldown
	if empty {
		cooldown = hongguoPlaybackEmptyCooldown
	}
	if state.health == nil {
		state.health = make(map[hongguoPlaybackRoute]hongguoPlaybackHealth)
	}
	health := state.health[route]
	health.blockedUntilMS = nowMS + cooldown.Milliseconds()
	health.empty = empty
	state.health[route] = health
}

// hongguoPlaybackNoteRound: one completed round: did every attempt end in
// an empty body?
func (state *hongguoPlaybackRouteState) NoteRound(allEmpty bool) {
	state.mu.Lock()
	defer state.mu.Unlock()
	if allEmpty {
		state.emptyRounds++
	} else {
		state.emptyRounds = 0
	}
}

func (state *hongguoPlaybackRouteState) EmptyRounds() uint32 {
	state.mu.Lock()
	defer state.mu.Unlock()
	return state.emptyRounds
}

// hongguoPlaybackRotationPaced: rotation pacing alone: a foreground caller,
// and a previous rotation that has settled. Independent of the empty streak
// so an in-round bail-out can reuse it.
func (state *hongguoPlaybackRouteState) RotationPaced(nowMS int64, speculative bool) bool {
	state.mu.Lock()
	defer state.mu.Unlock()
	if speculative {
		return false
	}
	cooldown := hongguoPlaybackRotateCooldownSettled
	if state.hasRotateInfo && !state.rotateOK {
		cooldown = hongguoPlaybackRotateCooldownFailed
	}
	if !state.hasRotated {
		return true
	}
	return nowMS-state.lastRotateMS >= cooldown.Milliseconds()
}

// hongguoPlaybackRotateDue: a foreground request may rotate identity when
// the empty streak is long enough and the previous rotation has settled.
func (state *hongguoPlaybackRouteState) RotateDue(nowMS int64, speculative bool) bool {
	if state.EmptyRounds() < hongguoPlaybackEmptyRotateRounds {
		return false
	}
	return state.RotationPaced(nowMS, speculative)
}

func (state *hongguoPlaybackRouteState) NoteRotate(nowMS int64, registered bool) {
	state.mu.Lock()
	defer state.mu.Unlock()
	state.lastRotateMS = nowMS
	state.hasRotated = true
	state.rotateOK = registered
	state.hasRotateInfo = true
	if registered {
		state.rotations++
	}
}

func (state *hongguoPlaybackRouteState) Rotations() uint32 {
	state.mu.Lock()
	defer state.mu.Unlock()
	return state.rotations
}
