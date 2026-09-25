package manifests

import _ "embed"

//go:embed workload.yaml
var workloadYAML []byte

func WorkloadManifestBytes() []byte {
	return workloadYAML
}
