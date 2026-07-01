package labels

// Domain holds all Ginkgo label strings used to classify and filter e2e tests.
var Domain = struct {
	BAT           string
	DPF           string
	Networking    string
	DPUDeployment string
	DPUService    string
	Upgrade       string
	MTU           string
	Critical      string
	Parallel      string
	Resiliency    string
	Stability     string
	BFB           string
	HCP           string
	RequiresBMC   string
	RequiresSSH   string
	RequiresNodes string
}{
	BAT:           "bat",
	DPF:           "dpf",
	Networking:    "networking",
	DPUDeployment: "dpudeployment",
	DPUService:    "dpuservice",
	Upgrade:       "upgrade",
	MTU:           "mtu",
	Critical:      "critical",
	Parallel:      "parallel",
	Resiliency:    "resiliency",
	Stability:     "stability",
	BFB:           "bfb",
	HCP:           "hcp",
	RequiresBMC:   "requires-bmc",
	RequiresSSH:   "requires-ssh",
	RequiresNodes: "requires-nodes",
}
