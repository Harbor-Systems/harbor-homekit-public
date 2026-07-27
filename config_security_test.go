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
		Streams map[string]any `yaml:"streams"`
		HomeKit map[string]any `yaml:"homekit"`
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
		"api", "rtsp", "webrtc", "exec", "ffmpeg", "homekit",
	})
}

// assertEqual reports a named structural configuration mismatch.
func assertEqual(t *testing.T, name string, got, want any) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%s = %#v, want %#v", name, got, want)
	}
}
