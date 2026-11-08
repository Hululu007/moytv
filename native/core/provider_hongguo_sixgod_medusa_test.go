package core

import (
	"testing"
)

func TestSixGodHeliosGolden(t *testing.T) {
	got := sixGodHelios(1760000000, 987654321)
	want := "sWjeOkjuCYGdqczEDPI6lyB6Tfhn/hzAr94ykTCXjznrDEmc"
	if got != want {
		t.Fatalf("helios mismatch\ngot:  %s\nwant: %s", got, want)
	}
}

func TestSixGodMedusaGolden(t *testing.T) {
	rawURL := "https://api.hongguo.com/test/play/?_rticket=1760000000000&aid=8662&app_name=novelread&device_brand=Redmi&device_id=1234567890&device_type=25053RT47C&iid=abcdef&os_version=16&version_code=73532&version_name=7.3.5.32"
	body := []byte(`{"mixed_video_id_map":{"1004":["1234567890"]}}`)
	opts := sixGodMedusaOpts{
		ProtoRand:  111111111,
		LaunchTime: 110,
		ProcessID:  10500,
		HashRand:   222222222,
		XMRand:     333333333,
		TimeSec:    1760000000,
	}
	got, err := sixGodGenMedusa(rawURL, body, 1760000000, opts)
	if err != nil {
		t.Fatalf("genMedusa error: %v", err)
	}
	want := "A3jnaPeQuJLXrztT1lIvGFe3hnCO1wAB4TUVQ84TAVQNGEjlal+MImbeu/RP2GQOasynKMOlViQckEZ5jG+No1ZJf4iins14ScJPALtKS6GMLrlqNmTjStfqzaxURosyYv1dr+1uViO+oxLI0wqBXvc2aFz/s5JWie8FjNExBmzFFGAMlg+eVhO43p8fnMJ/O4CsMhdhSFpTd/V1U7m4wu0QyRRDpO+wRggt5KF5fRy6HGwY0BGPXWCK2INJjNXp/PY9aBmJKsTTSK/vMoKlaOIM6KWnAU3OJLpW/2+VsoWgPX7Tp2gtx9SjNhG9YMOff6yLxVP6X2k3TTyzfrdaeiHZz2aYGwxjnwHckzaRFdztfsN3a0VKrakZWEe7v+IIVkd2pIbXyY2Ih6Eb8lAh2L/wCtAAiQfCyjUE89EU5HR8fF35hwCnC8ZKu+JqCuHnncTE5gHRwrACguLaOemj6HmCf1cXGgfBWiwRzaVlaUAb2ZzLNRvdcmr6Xd7FCFmd6gaYlXGHWkMPh9Isq2QAFwrryH1XFy+2Z7zgi+EOPWh+Zr/G7EKexJPZFxwEdYutVTAedU5AaIUzc/LJ56ECrdY87fYdTzcaQ+4t05aUQq5aur4YoAPxqCrLEJx7uKUEbX2NVISerbNdCVcBcrBmy6/fIzyY8QxoordO9z4dOCzgcTb+Fl/KcZxfExVUmA4qqQk9apQd+NbfnGzCthhmunVgNjsToxQgmHZxuFMfcO2/ApU6SaQ1vn8bDv9hDjrra9bvjZ6leMXxcNcYsZMPECjwrUnKiuX7xg7nnLlSTYlHCP9PxMAkWH+oSDY/Yjdk9ZA7vZzVqVl1EZTcEMpw6EzJKMopzEfV5QMlUELz/tp2NomESJRRd8Nf2hGvxgkq7KqQ1t+hSb0Pzf/+D83+vj4N"
	if got != want {
		t.Fatalf("medusa mismatch\ngot:  %s\nwant: %s", got, want)
	}
}
