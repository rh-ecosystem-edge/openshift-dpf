package manifests

import _ "embed"

//go:embed regular_worker_workload.yaml
var regularWorkerWorkloadYAML []byte

func RegularWorkerWorkloadManifestBytes() []byte {
	return regularWorkerWorkloadYAML
}