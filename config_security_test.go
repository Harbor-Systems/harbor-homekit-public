package homekit_test

import (
	"bytes"
	"os"
	"reflect"
	"testing"

	"gopkg.in/yaml.v3"
)

// TestGo2RTCConfigHasExactSecurityBoundary parses effective YAML, including
// duplicate-key errors, instead of trusting comments or decoy text.
func TestGo2RTCConfigHasExactSecurityBoundary(t *testing.T) {
	data, err := os.ReadFile("go2rtc.yaml")
	if err != nil {
		t.Fatal(err)
	}

	var config struct {
		App struct {
			Modules []string `yaml:"modules"`
		} `yaml:"app"`
		API struct {
			Listen     string   `yaml:"listen"`
			AllowPaths []string `yaml:"allow_paths"`
		} `yaml:"api"`
		RTSP struct {
			Listen string `yaml:"listen"`
		} `yaml:"rtsp"`
		Exec struct {
			AllowPaths []string `yaml:"allow_paths"`
		} `yaml:"exec"`
		FFmpeg        map[string]string `yaml:"ffmpeg"`
		Streams       map[string]any    `yaml:"streams"`
		HomeKit       map[string]any    `yaml:"homekit"`
		HomeKitListen string            `yaml:"homekit_listen"`
	}
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	decoder.KnownFields(true)
	if err := decoder.Decode(&config); err != nil {
		t.Fatalf("parse go2rtc.yaml: %v", err)
	}

	assertEqual(t, "api.listen", config.API.Listen, "127.0.0.1:1985")
	assertEqual(t, "rtsp.listen", config.RTSP.Listen, "127.0.0.1:8554")
	assertEqual(t, "api.allow_paths", config.API.AllowPaths, []string{"/api/streams", "/api/webrtc"})
	assertEqual(t, "exec.allow_paths", config.Exec.AllowPaths, []string{"ffmpeg"})
	assertEqual(t, "app.modules", config.App.Modules, []string{
		"api", "rtsp", "webrtc", "exec", "ffmpeg", "homekit", "srtp",
	})
	assertEqual(t, "homekit_listen", config.HomeKitListen, ":21063")
	if len(config.Streams) != 1 {
		t.Fatalf("streams keys = %#v, want only CAMERA_SERIAL", config.Streams)
	}
	streamSources, ok := config.Streams["CAMERA_SERIAL"].([]any)
	if !ok {
		t.Fatalf("streams.CAMERA_SERIAL = %#v, want a source list", config.Streams["CAMERA_SERIAL"])
	}
	assertEqual(t, "streams.CAMERA_SERIAL", streamSources, []any{
		"ffmpeg:CAMERA_SERIAL#video=h264#audio=opus#raw=-vf scale=-2:720,setpts=(RTCTIME-RTCSTART)/(TB*1000000) -bsf:v dump_extra=freq=keyframe -x264-params sliced-threads=0 -ar 16000 -ac 1 -b:a 24k",
	})
	// Apple's HomeKit receiver negotiates H264 Main 4.0; go2rtc's built-in
	// template encodes High 4.1, so the config must override it.
	assertEqual(t, "ffmpeg.h264", config.FFmpeg["h264"],
		"-c:v libx264 -g 50 -profile:v main -level:v 4.0 -preset:v superfast -tune:v zerolatency -pix_fmt:v yuv420p")
	if len(config.HomeKit) != 1 {
		t.Fatalf("homekit keys = %#v, want only CAMERA_SERIAL", config.HomeKit)
	}
	if _, ok := config.HomeKit["CAMERA_SERIAL"]; !ok {
		t.Fatal("homekit must contain CAMERA_SERIAL")
	}
}

// assertEqual reports a named structural configuration mismatch.
func assertEqual(t *testing.T, name string, got, want any) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%s = %#v, want %#v", name, got, want)
	}
}
