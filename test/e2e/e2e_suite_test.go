package e2e_test

import (
	"flag"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"
)

var (
	configPath string
)

func init() {
	flag.StringVar(&configPath, "e2e.config", "config/config-bat.yaml",
		"Path to e2e YAML config file")
}

func TestE2E(t *testing.T) {
	gomega.RegisterFailHandler(Fail)
	RunSpecs(t, "DPF OCP E2E Suite")
}
