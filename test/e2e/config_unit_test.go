package e2e

import (
	"testing"
	"time"
)

func TestParsePositiveDuration(t *testing.T) {
	tests := []struct {
		name    string
		value   string
		want    time.Duration
		wantErr bool
	}{
		{name: "minutes", value: "30m", want: 30 * time.Minute},
		{name: "hours", value: "1h", want: time.Hour},
		{name: "malformed", value: "30 minutes", wantErr: true},
		{name: "zero", value: "0s", wantErr: true},
		{name: "negative", value: "-5m", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parsePositiveDuration("CLUSTER_HEALTH_TIMEOUT", tt.value)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("parsePositiveDuration(%q) unexpectedly succeeded", tt.value)
				}
				return
			}
			if err != nil {
				t.Fatalf("parsePositiveDuration(%q) returned error: %v", tt.value, err)
			}
			if got != tt.want {
				t.Fatalf("parsePositiveDuration(%q) = %s, want %s", tt.value, got, tt.want)
			}
		})
	}
}
