#!/usr/bin/env python3
"""NNO day-1 coordinator around aicli, not a replacement Assisted client.

Keeps host identity, start gates and owned recovery state separate from the
worker boot method. Existing shell helpers still handle libvirt and manifests.
Only exact disk-ID updates need the installed aicli client's API directly.
"""
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import sys
import tempfile
import time
from urllib.parse import parse_qs, urlsplit

# Redfish shares these exception classes when this file is the CLI entry point.
# Keep one module identity so its failures reach the CLI's redacted error handler.
if __name__ == "__main__":
    sys.modules["assisted_install"] = sys.modules[__name__]

SCRIPT_DIR = Path(__file__).resolve().parent
PRE_INSTALL = {"insufficient", "pending-for-input", "ready"}
INSTALLING = {"preparing-for-installation", "installing", "finalizing", "installing-pending-user-action"}
INSTALLED = {"installed", "adding-hosts"}


class Error(RuntimeError):
    pass


class Pending(Error):
    """Inventory or validation may still converge; never used for conflicts."""


def require(condition, message, error=Error):
    if not condition:
        raise error(message)


def log(message):
    print(f"[INFO] {message}", file=sys.stderr, flush=True)


def mac(value, strict=True):
    compact = re.sub(r"[:-]", "", value).lower() if isinstance(value, str) else ""
    if re.fullmatch(r"[0-9a-f]{12}", compact) and not (int(compact[:2], 16) & 1) and compact != "0" * 12:
        return ":".join(compact[i:i + 2] for i in range(0, 12, 2))
    require(not strict, "Identifying MAC must be a valid, nonzero unicast address")


def hostname(value):
    return (0 < len(value) <= 63 and re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", value)
            and not value.isdigit())


def workers(env):
    return [{"index": i, "name": env.get(f"WORKER_{i}_NAME", ""),
             "mac": env.get(f"WORKER_{i}_BOOT_MAC", ""), "role": "worker",
             "disk": env.get(f"WORKER_{i}_ROOT_DEVICE") or "/dev/sda"}
            for i in range(1, int(env.get("WORKER_COUNT", "0")) + 1)]


def worker_boot_driver(env):
    """Select a boot implementation; each supplies validate/preflight/boot/cleanup.

    Keep method selection here so another transport does not change the
    Assisted Installer host discovery, installation or verification flow.
    """
    method = env.get("WORKER_BOOT_METHOD", "redfish-virtualmedia")
    if method == "redfish-virtualmedia":
        from assisted_redfish import Redfish
        return Redfish
    raise Error(f"Unsupported WORKER_BOOT_METHOD={method}; supported: redfish-virtualmedia")


def worker_boot(env, worker, record=None):
    driver = worker_boot_driver(env)
    # Records from before method selection was explicit used Redfish.
    if record and record.get("boot_method", "redfish-virtualmedia") != driver.method:
        raise Error(f"{worker['name']}: boot method changed while media ownership exists")
    return driver(env, worker)


def validate(env):
    require(env.get("DEPLOYMENT_PROFILE", "dpf") == "nno", "day1-assisted requires DEPLOYMENT_PROFILE=nno")
    require(env.get("VM_COUNT", "3") == "3" and env.get("VM_WORKER_COUNT", "0") == "0",
            "day1-assisted requires VM_COUNT=3 and VM_WORKER_COUNT=0")
    require(env.get("DPF_DEPLOYMENT_MODE", "host-trusted") == "host-trusted", "day1-assisted does not support zero-trust")
    require(re.fullmatch(r"0|[1-9][0-9]*", env.get("WORKER_COUNT", "0")), "WORKER_COUNT must be a nonnegative integer")
    require(env.get("NODES_MTU", "1500") in {"1500", "9000"}, "NODES_MTU must be 1500 or 9000")
    require(env.get("ARCH", "x86_64") in {"x86_64", "amd64", "aarch64", "arm64"},
            "day1-assisted requires a single x86_64 or aarch64 architecture")
    require(env.get("ISO_TYPE", "minimal") in {"minimal", "full"}, "ISO_TYPE must be minimal or full")
    for key in ("API_VIP", "INGRESS_VIP"):
        try:
            ipaddress.IPv4Address(env.get(key, ""))
        except ipaddress.AddressValueError as exc:
            raise Error(f"{key} must be a valid IPv4 address for day1-assisted") from exc
    prefix = env.get("VM_PREFIX", "vm-nno")
    names = {f"{prefix}{i}" for i in range(1, 4)}
    require(all(hostname(n) for n in names), "VM_PREFIX must yield valid lowercase single-label hostnames")
    custom = env.get("MAC_PREFIX", "")
    require(not custom or re.fullmatch(r"[0-9a-fA-F]{2}:[0-9a-fA-F]{2}", custom), "MAC_PREFIX must contain two hex octets")
    macs = set()
    for worker in workers(env):
        key = f"WORKER_{worker['index']}_"
        require(env.get(key + "DPU", "false") in {"", "false"} and not env.get(key + "DPU_BMC_IPS"),
                f"{key}DPU must resolve to false; DPU workers are outside day1-assisted scope")
        require(hostname(worker["name"]) and worker["name"] not in names,
                f"{key}NAME must be a unique lowercase single-label hostname (maximum 63 characters)")
        names.add(worker["name"])
        address = mac(worker["mac"])
        require(address not in macs, f"{key}BOOT_MAC duplicates another worker")
        macs.add(address)
        require(worker["disk"].startswith("/dev/") and not re.search(r"[\s\x00-\x1f]", worker["disk"]),
                f"{key}ROOT_DEVICE must be a /dev/ path")
    worker_boot_driver(env).validate_config(env)


def json_value(value, default):
    if not value:
        return default
    return json.loads(value) if isinstance(value, str) else value


def host_macs(host):
    inventory = json_value(host.get("inventory"), {})
    # Ignore non-Ethernet inventory (including InfiniBand); configured MACs stay strict.
    return set(filter(None, (mac(interface.get("mac_address"), strict=False)
                             for interface in inventory.get("interfaces", []))))


def architecture(value):
    return {"arm64": "aarch64", "amd64": "x86_64"}.get(value, value)


def map_hosts(expected, hosts, cluster_id, infra_id, arch, complete=True):
    """Discovery is independent of known/ready; conflicts fail immediately."""
    mapped, claimed = {}, set()
    for entry in expected:
        matches = [h for h in hosts if entry["mac"] in host_macs(h)]
        require(len(matches) <= 1, f"Duplicate discovery identity for {entry['name']} ({entry['mac']})")
        if not matches:
            if complete:
                raise Pending(f"Missing host {entry['name']} ({entry['mac']}); waiting for inventory")
            continue
        host = matches[0]
        require(host.get("cluster_id") == cluster_id and host.get("infra_env_id") == infra_id,
                f"{entry['name']} belongs to another cluster or InfraEnv; refusing takeover")
        require(host["id"] not in claimed, "One discovered host matches multiple configured machines")
        claimed.add(host["id"])
        inv = json_value(host.get("inventory"), {})
        actual_arch = inv.get("cpu", {}).get("architecture")
        require(actual_arch, f"{entry['name']}: CPU inventory is not available", Pending)
        require(architecture(actual_arch) == architecture(arch),
                f"Wrong architecture for {entry['name']}: {actual_arch}, expected {arch}")
        mapped[entry["name"]] = host
    unexpected = [h for h in hosts if (h.get("cluster_id") == cluster_id or h.get("infra_env_id") == infra_id)
                  and h["id"] not in claimed]
    if unexpected:
        # A registering host may not yet have interfaces. Wait for its inventory,
        # but never start or assign a role to an unidentified host.
        if any(not host_macs(h) for h in unexpected):
            raise Pending("An unidentified host is still collecting discovery inventory")
        raise Error("Unexpected hosts in initial cluster/InfraEnv: " + ", ".join(h["id"] for h in unexpected))
    return mapped


def installation_disk(entry, host):
    requested = entry["disk"]
    disks = json_value(host.get("inventory"), {}).get("disks", [])
    found = [d for d in disks if requested in {d.get("id"), d.get("path"), d.get("by_path"),
                                               d.get("by_id"), "/dev/" + d.get("name", "")}]
    require(len(found) == 1, f"{entry['name']}: {requested} must resolve to exactly one discovered disk")
    disk = found[0]
    eligibility = disk.get("installation_eligibility") or {}
    require(eligibility.get("eligible") is True and not disk.get("removable") and not disk.get("is_installation_media"),
            f"{entry['name']}: {requested} is not eligible: {eligibility.get('not_eligible_reasons', [])}")
    require(disk.get("id"), f"{entry['name']}: installation disk has no ID")
    return disk["id"]


def iso_url(value):
    # Image type is selected on InfraEnv. Never rewrite the authenticated URL.
    url = value.strip()
    parts = urlsplit(url)
    assisted_endpoint = (re.fullmatch(r"/api/assisted-images/images/[a-zA-Z0-9-]+", parts.path) and
                         parse_qs(parts.query).get("type", [""])[0] in {"minimal-iso", "full-iso"})
    if (parts.scheme != "https" or not parts.netloc or parts.username or parts.fragment or
            parts.hostname in {"console.redhat.com", "console.openshift.com"} or
            not (parts.path.endswith(".iso") or assisted_endpoint) or any(c.isspace() for c in url)):
        raise Error("Assisted Installer did not return a usable discovery ISO URL")
    return url


def run(args, *, data=None, capture=True, timeout=180):
    child_env = dict(os.environ)
    # env.sh's guard applies inside one shell, not across subprocess shells.
    child_env.pop("ENV_SH_SOURCED", None)
    try:
        result = subprocess.run([str(a) for a in args], input=data, text=True,
                                stdout=subprocess.PIPE if capture else None,
                                stderr=subprocess.PIPE if capture else None,
                                timeout=timeout, check=False, env=child_env)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Error(f"{Path(args[0]).name}: command unavailable or timed out") from exc
    if result.returncode:
        # aicli/curl errors may repeat credentials, pull secrets, or signed URLs.
        raise Error(f"{Path(args[0]).name} {args[1] if len(args) > 1 else ''} failed (exit {result.returncode}); "
                    "check connectivity, credentials, and supported operations")
    return result.stdout or ""


def ai_json(*args):
    return json.loads(run(["aicli", "-o", "json", *args]))


def ai_write(action, kind, ident, params):
    # JSON is also YAML and keeps secrets out of process arguments.
    with tempfile.TemporaryDirectory(prefix="assisted-params-") as directory:
        path = Path(directory) / "params.json"
        path.write_text(json.dumps(params))
        path.chmod(0o600)
        run(["aicli", action, kind, ident, "--paramfile", str(path)])


def set_exact_disk(infra_id, host_id, disk_id):
    """Run with aicli's interpreter: its CLI rewrites disk IDs to /dev/basename."""
    try:
        from ailib import AssistedClient
        from assisted_service_client.models import HostUpdateParams

        # Same endpoint/authentication contract as ailib.cli; no credential store.
        url = os.environ.get("AI_URL")
        if url is None:
            environment = ""
            if os.environ.get("AI_STAGING"):
                environment = "stage."
            elif os.environ.get("AI_INTEGRATION"):
                environment = "integration."
            url = f"https://api.{environment}openshift.com"
        client = AssistedClient(url, token=os.environ.get("AI_TOKEN"), offlinetoken=os.environ.get("AI_OFFLINETOKEN"),
                                ca=os.environ.get("AI_CA"), cert=os.environ.get("AI_CERT"), key=os.environ.get("AI_KEY"))
        params = HostUpdateParams(disks_selected_config=[{"id": disk_id, "role": "install"}])
        client.client.v2_update_host(infra_env_id=infra_id, host_id=host_id, host_update_params=params)
    except Exception as exc:
        raise Error("Exact installation disk update failed; verify aicli/assisted-service-client compatibility") from exc


def atomic_bytes(path, data):
    """Publish private data without a readable-file or symlink-following window."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".assisted-")
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


class Installer:
    def __init__(self, env=None):
        self.env = dict(os.environ if env is None else env)
        validate(self.env)
        self.name = self.env["CLUSTER_NAME"]
        self.domain = self.env["BASE_DOMAIN"]
        self.arch = architecture(self.env.get("ARCH", "x86_64"))
        # Names are hashed to avoid path traversal and collisions across domains.
        key = hashlib.sha256(f"{self.name}.{self.domain}".encode()).hexdigest()[:20]
        self.directory = Path(".assisted-day1") / key
        self.path = self.directory / "state.json"
        self.state = json.loads(self.path.read_text()) if self.path.exists() else {}
        self.vm_identity = {key: self.env.get(key, "") for key in ("VM_PREFIX", "MAC_PREFIX", "LIBVIRT_HOST")}
        if self.state.get("vm_identity") and self.state["vm_identity"] != self.vm_identity:
            raise Error("Configured control-plane identity or libvirt host changed; retain the original deployment configuration")
        # Preserve the mapping even if libvirt is offline or teardown already
        # removed the domains. Inventory gates detect replaced interfaces.
        controls = [(e["name"], e["mac"]) for e in self.state.get("expected", []) if e["role"] == "master"]
        names = {f"{self.env.get('VM_PREFIX', 'vm-nno')}{i}" for i in range(1, 4)}
        if controls and {name for name, _ in controls} != names:
            raise Error("Configured control-plane names changed")
        controls = controls or json.loads(run(["bash", SCRIPT_DIR / "assisted-cluster.sh", "vm-macs"]))
        self.expected = [{"name": name, "mac": mac(address), "role": "master"} for name, address in controls]
        self.expected += [{**w, "mac": mac(w["mac"])} for w in workers(self.env)]
        require(len(self.expected) == len({e["mac"] for e in self.expected}),
                "Configured control-plane and worker MACs must all be unique")
        self.cluster = None
        self.infra = None

    def save(self):
        atomic_bytes(self.path, (json.dumps(self.state, indent=2) + "\n").encode())

    def resolve(self, absent=False):
        clusters = ai_json("list", "clusters")
        pinned = self.state.get("cluster_id")
        candidates = [c for c in clusters if c.get("id") == pinned] if pinned else [
            c for c in clusters if c.get("name") == self.name and c.get("base_dns_domain") == self.domain]
        require(len(candidates) <= 1, "Ambiguous initial cluster; refusing to choose by name or list order")
        if not candidates:
            if pinned or not absent:
                raise Error("Pinned initial cluster is missing; do not switch modes or recreate it implicitly")
            return None
        cluster = ai_json("info", "cluster", candidates[0]["id"])
        require(cluster.get("name") == self.name and cluster.get("base_dns_domain") == self.domain,
                "Pinned cluster identity changed")
        require(architecture(cluster.get("cpu_architecture")) == self.arch, "Initial cluster architecture does not match ARCH")
        require(self.state, "Existing cluster has no day1-assisted ownership record; use the original provisioning workflow")
        require(self.state.get("expected") == self.expected,
                "Configured inventory changed; day1-assisted is not an expansion or reprovisioning workflow")
        self.cluster = cluster
        self.state["cluster_id"] = cluster["id"]
        infraenvs = ai_json("list", "infraenvs")
        matches = [i for i in infraenvs if i.get("cluster_id") == cluster["id"] and
                   architecture(i.get("cpu_architecture")) == self.arch]
        if self.state.get("infra_env_id"):
            matches = [i for i in matches if i["id"] == self.state["infra_env_id"]]
        require(len(matches) <= 1, "Multiple initial InfraEnvs; refusing ambiguous discovery image selection")
        self.infra = matches[0] if matches else None
        require(not self.state.get("infra_env_id") or self.infra, "Pinned initial InfraEnv is missing")
        status = cluster["status"]
        if status not in PRE_INSTALL | INSTALLING | INSTALLED:
            raise Error(f"Cluster {self.cluster['id']} is {status}: {self.cluster.get('status_info', '')}; "
                        "inspect installer diagnostics; no automatic reset or reinstall")
        if self.state.get("removed") and status in PRE_INSTALL | INSTALLING:
            raise Error("A configured initial worker was removed; do not resume installation with a changed inventory")
        return cluster

    def mapped(self, complete=True):
        require(self.infra, "Initial InfraEnv is missing")
        return map_hosts(self.expected, ai_json("list", "hosts"), self.cluster["id"], self.infra["id"], self.arch, complete)

    def ownership_check(self):
        # Cross-cluster discovery inventory is checked even before creating a cluster.
        current = self.cluster["id"] if self.cluster else None
        infra_id = self.infra["id"] if self.infra else None
        for host in ai_json("list", "hosts"):
            if any(w["mac"] in host_macs(host) for w in self.expected if w["role"] == "worker"):
                if host.get("cluster_id") != current or host.get("infra_env_id") != infra_id or not current:
                    raise Error(f"Worker MAC is registered to another cluster/InfraEnv ({host['id']}); refusing takeover")
        kubeconfig = self.env.get("KUBECONFIG", "kubeconfig")
        if Path(kubeconfig).is_file():
            # Failure to inspect existing ownership is a failure, never permission to boot.
            resources = json.loads(run(["oc", "get", "baremetalhosts.metal3.io", "-A", "-o", "json"]))
            for bmh in resources["items"]:
                spec = bmh.get("spec", {})
                boot_mac = spec.get("bootMACAddress", "")
                address = spec.get("bmc", {}).get("address", "")
                for w in workers(self.env):
                    bmc = self.env.get(f"WORKER_{w['index']}_BMC_IP")
                    bmc_host = urlsplit(address.replace("redfish-virtualmedia+", "")).hostname
                    if (boot_mac and mac(boot_mac) == mac(w["mac"])) or (bmc and bmc_host == bmc):
                        raise Error(f"Worker {w['name']} already has BareMetalHost ownership; refusing conversion")

    def preflight(self):
        self.ownership_check()
        # Validate local inputs and Python dependency before any installer/BMC mutation.
        import yaml  # noqa: F401
        for key in ("OPENSHIFT_PULL_SECRET", "SSH_KEY"):
            if not Path(self.env.get(key, "")).is_file():
                raise Error(f"{key} must point to a readable file")
        resolved = set()
        for w in workers(self.env):
            record = self.state.get("media", {}).get(w["name"])
            backend = worker_boot(self.env, w, record)
            ident = backend.preflight(record)
            if ident in resolved:
                raise Error("Two workers resolve to the same boot target")
            resolved.add(ident)
            log(f"{w['name']}: {backend.method} preflight passed")

    def create(self):
        if self.resolve(absent=True):
            return
        self.preflight()
        run(["bash", SCRIPT_DIR / "utils.sh", "verify-files"], capture=False)
        self.state = {"expected": self.expected, "vm_identity": self.vm_identity, "name": self.name, "domain": self.domain,
                      "media": {}, "creating": True}
        self.save()
        params = {"openshift_version": self.env["OPENSHIFT_VERSION"], "cpu_architecture": self.arch,
                  "base_dns_domain": self.domain, "pull_secret": self.env["OPENSHIFT_PULL_SECRET"],
                  "api_vips": [self.env["API_VIP"]], "ingress_vips": [self.env["INGRESS_VIP"]], "infraenv": False}
        public_key = self.env.get("SSH_KEY")
        if public_key:
            params["public_key"] = public_key
        ai_write("create", "cluster", self.name, params)
        self.resolve()
        self.save()

    def network(self, output=None):
        import yaml
        static = Path(self.env.get("STATIC_NET_FILE", "manifests/generated/static_net.yaml"))
        config = yaml.safe_load(static.read_text()) if static.exists() else {}
        entries = (config or {}).get("static_network_config", [])
        # Worker names are logical names mapped to physical interfaces by MAC,
        # independent of PRIMARY_IFACE on the control-plane VMs.
        for w in workers(self.env):
            entries.append({"mac_interface_map": [{"mac_address": mac(w["mac"]), "logical_nic_name": "bootnic"}],
                            "network_yaml": yaml.safe_dump({"interfaces": [{"name": "bootnic", "type": "ethernet",
                                "state": "up", "mtu": int(self.env.get("NODES_MTU", "1500")),
                                "ipv4": {"enabled": True, "dhcp": True}}]})})
        params = {"static_network_config": entries}
        if output is not None:
            output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            output.write_text(yaml.safe_dump(params))
        return params

    def prepare_infra(self):
        self.resolve()
        if self.cluster["status"] not in PRE_INSTALL:
            return
        self.preflight()
        run(["bash", SCRIPT_DIR / "assisted-cluster.sh", "network-input"], capture=False)
        params = {"image_type": {"minimal": "minimal-iso", "full": "full-iso"}[self.env.get("ISO_TYPE", "minimal")]}
        params.update(self.network())
        if not self.infra:
            params.update({"cluster_id": self.cluster["id"], "cpu_architecture": self.arch,
                           "openshift_version": self.env["OPENSHIFT_VERSION"],
                           "pull_secret": self.env["OPENSHIFT_PULL_SECRET"], "public_key": self.env["SSH_KEY"]})
            # Disallow colliding names as aicli cannot create them unambiguously.
            ai_write("create", "infraenv", self.name + "_infra-env", params)
        else:
            ai_write("update", "infraenv", self.infra["id"], params)
        self.resolve()
        self.state["infra_env_id"] = self.infra["id"]
        self.save()

    def image(self):
        if not self.infra:
            raise Error("No initial discovery InfraEnv")
        # Refreshes expiring SaaS URLs using aicli's existing token store.
        raw = run(["aicli", "info", "iso", self.infra["id"], "-s"])
        return iso_url(re.sub(r"\x1b\[[0-9;]*m", "", raw))

    def boot(self):
        self.resolve()
        if self.cluster["status"] not in PRE_INSTALL:
            log("Installation has started; skipping physical-worker boot")
            return
        self.preflight()
        for w in workers(self.env):
            self.resolve()  # Recheck live state immediately before each worker mutation.
            if self.cluster["status"] not in PRE_INSTALL:
                return
            mapped = self.wait(lambda: self.mapped(complete=False))
            if w["name"] in mapped:
                log(f"{w['name']}: already discovered; preserving its boot session")
                continue
            record = self.state.setdefault("media", {}).get(w["name"])
            def save_record(value):
                self.state["media"][w["name"]] = value
                self.save()
            worker_boot(self.env, w, record).boot(self.image(), record, save_record)
            log(f"{w['name']}: discovery boot requested")

    def wait(self, probe, attempts=None, delay=None):
        attempts = int(attempts or self.env.get("MAX_RETRIES", "90"))
        delay = float(delay if delay is not None else self.env.get("SLEEP_TIME", "60"))
        for attempt in range(attempts):
            try:
                return probe()
            except Pending as exc:
                log(str(exc))
                if attempt + 1 < attempts:
                    time.sleep(delay)
        raise Error("Timed out; discovery and validation diagnostics are shown above. Resume after resolving them.")

    def configure(self):
        mapped = self.wait(self.mapped)
        self.resolve()
        if self.cluster["status"] not in PRE_INSTALL:
            raise Error("Installation started during discovery; refusing host mutations")
        # Validate every disk before changing any host.
        disks = {e["name"]: installation_disk(e, mapped[e["name"]]) for e in self.expected if e["role"] == "worker"}
        for entry in self.expected:
            self.resolve()
            if self.cluster["status"] not in PRE_INSTALL:
                raise Error("Installation started during host preparation; refusing host mutations")
            host = mapped[entry["name"]]
            ai_write("update", "host", host["id"], {"infraenv": self.infra["id"],
                                                    "requested_hostname": entry["name"], "role": entry["role"]})
            if entry["role"] == "worker":
                self.set_disk(host, disks[entry["name"]])
        self.state["host_ids"] = {name: host["id"] for name, host in mapped.items()}
        self.save()

    def set_disk(self, host, disk_id):
        # aicli normalizes every disk argument to /dev/<basename>. Preserve exact
        # discovered IDs through the same ailib client only for this missing operation.
        executable = shutil.which("aicli")
        first = Path(executable).read_text().splitlines()[0] if executable else ""
        interpreter = shlex.split(first[2:]) if first.startswith("#!/") and "python" in first else [sys.executable]
        run([*interpreter, SCRIPT_DIR / "assisted_install.py", "set-disk", self.infra["id"], host["id"], disk_id])

    def gate(self):
        self.resolve()
        require(self.cluster["status"] in PRE_INSTALL, "Cluster is no longer in a pre-installation state")
        mapped = self.mapped()
        for entry in self.expected:
            host = mapped[entry["name"]]
            require(host.get("role") == entry["role"] and host.get("requested_hostname") == entry["name"],
                    f"{entry['name']}: waiting for requested hostname and role", Pending)
            if entry["role"] == "worker" and host.get("installation_disk_id") != installation_disk(entry, host):
                raise Pending(f"{entry['name']}: waiting for installation disk selection")
            require(host.get("status") not in {"error", "cancelled", "disabled"},
                    f"{entry['name']}: {host.get('status')}: {host.get('status_info', '')}")
            require(host.get("status") == "known", f"{entry['name']}: {host.get('status')}: {host.get('status_info', '')}; "
                                                 f"validations={host.get('validations_info', '')}", Pending)
        require(self.cluster["status"] == "ready", f"Cluster {self.cluster['id']}: {self.cluster['status']}; "
                                                 f"validations={self.cluster.get('validations_info', '')}", Pending)
        return mapped

    def install(self):
        self.resolve()
        if self.cluster["status"] in PRE_INSTALL:
            if self.state.get("start_requested"):
                raise Error("A start was already requested but the cluster is still pre-installation; "
                            "inspect the installer result before retrying. No second start was sent.")
            self.configure()
            self.wait(self.gate)
            mapped = self.gate()  # Fresh exact-host gate immediately before the start call.
            self.state["host_ids"] = {name: h["id"] for name, h in mapped.items()}
            self.state["start_requested"] = True
            self.save()
            run(["aicli", "start", "cluster", self.cluster["id"]])
        def installed():
            self.resolve()
            self.check_pinned_hosts()
            require(self.cluster["status"] in INSTALLED, f"Cluster {self.cluster['id']}: {self.cluster['status']}", Pending)
        self.wait(installed, attempts=120)

    def check_pinned_hosts(self):
        if self.state.get("removed"):
            raise Error("An initial worker was removed; use an explicit expansion or reprovisioning workflow, not initial installation")
        mapped = self.mapped()
        actual = {name: h["id"] for name, h in mapped.items()}
        require(self.state.get("host_ids") == actual, "Initial host registrations changed; refusing implicit adoption or expansion")
        return mapped

    def credentials(self):
        self.resolve()
        destination = Path(self.env.get("KUBECONFIG", "kubeconfig"))
        with tempfile.TemporaryDirectory(prefix="assisted-kubeconfig-") as directory:
            run(["aicli", "download", "kubeconfig", self.cluster["id"], "--path", directory])
            source = Path(directory) / f"kubeconfig.{self.cluster['id']}"
            atomic_bytes(destination, source.read_bytes())

    def nodes(self):
        return json.loads(run(["oc", "get", "nodes", "-o", "json"]))["items"]

    @staticmethod
    def node_ready(node):
        return any(c["type"] == "Ready" and c["status"] == "True" for c in node.get("status", {}).get("conditions", []))

    def verify_nodes(self):
        self.resolve()
        mapped = self.check_pinned_hosts()
        def check():
            nodes = self.nodes()
            for entry in self.expected:
                matches = [n for n in nodes if n["metadata"]["name"] == entry["name"] or
                           n["metadata"]["name"] == f"{entry['name']}.{self.name}.{self.domain}"]
                if len(matches) != 1:
                    host = mapped[entry["name"]]
                    raise Pending(f"{entry['name']}: expected installed node missing/ambiguous; "
                                  f"Assisted status={host.get('status')}, {host.get('status_info', '')}")
                node = matches[0]
                labels = node["metadata"].get("labels", {})
                is_master = any(f"node-role.kubernetes.io/{role}" in labels for role in ("master", "control-plane"))
                if is_master != (entry["role"] == "master") or (entry["role"] == "worker" and
                        "node-role.kubernetes.io/worker" not in labels):
                    raise Error(f"{entry['name']}: installed node has the wrong role")
                require(self.node_ready(node), f"{entry['name']}: waiting for Ready=True", Pending)
            log(f"All {len(self.expected)} configured NNO nodes are Ready with the expected roles")
        self.wait(check, self.env.get("VERIFY_MAX_RETRIES", "60"), self.env.get("VERIFY_SLEEP_SECONDS", "30"))

    def cleanup_media(self, only=None, teardown=False):
        self.resolve()
        if not teardown and self.cluster["status"] not in INSTALLED:
            raise Error("Discovery media is still needed; cleanup before installation completes requires explicit teardown")
        for worker in workers(self.env):
            if only and only != worker["name"]:
                continue
            record = self.state.get("media", {}).get(worker["name"])
            if record:
                worker_boot(self.env, worker, record).cleanup(record)
                del self.state["media"][worker["name"]]
                self.save()

    def status(self):
        self.resolve()
        mapped = self.mapped(complete=False)
        nodes = self.nodes() if Path(
            self.env.get("KUBECONFIG", "kubeconfig")).is_file() else []
        for worker in workers(self.env):
            host = mapped.get(worker["name"], {})
            node = next((n for n in nodes if n["metadata"]["name"].split(".")[0] == worker["name"]), {})
            print(f"{worker['name']}: Assisted={host.get('status', 'not-discovered')}, "
                  f"Node={node.get('metadata', {}).get('name', 'not-joined')}, Ready={self.node_ready(node)}")

    def delete_worker(self, name):
        matches = [w for w in workers(self.env) if name == w["name"]]
        require(len(matches) == 1, "delete-worker requires a configured physical worker name; control-plane targets are forbidden")
        self.resolve()
        mapped = self.mapped(complete=False)
        worker = matches[0]
        nodes = self.nodes()
        targets = [n for n in nodes if n["metadata"]["name"] in {name, f"{name}.{self.name}.{self.domain}"}]
        if len(targets) > 1 or any(any(f"node-role.kubernetes.io/{role}" in n["metadata"].get("labels", {})
                                     for role in ("master", "control-plane")) for n in targets):
            raise Error("Refusing an ambiguous or control-plane deletion target")
        log(f"Removing {name}; workloads must already be evacuated. Installed disk contents will remain intact.")
        run(["bash", SCRIPT_DIR / "assisted-cluster.sh", "power-off", str(worker["index"])], capture=False)
        self.cleanup_media(name, teardown=True)
        for node in targets:
            run(["oc", "delete", "node", node["metadata"]["name"]])
        if name in mapped:
            run(["aicli", "delete", "host", mapped[name]["id"], "-y"])
        self.state.setdefault("removed", []).append(name)
        self.save()

    def delete_cluster(self):
        self.resolve()
        self.cleanup_media(teardown=True)
        # Only pinned records are removed. Do not touch same-name day-2 clusters.
        if self.infra:
            for host in ai_json("list", "hosts"):
                if host.get("infra_env_id") == self.infra["id"]:
                    run(["aicli", "delete", "host", host["id"], "-y"])
            run(["aicli", "delete", "infraenv", self.infra["id"], "-y"])
        run(["aicli", "delete", "cluster", self.cluster["id"], "-y"])
        shutil.rmtree(self.directory)

    def workflow(self):
        self.create()
        self.download()
        if self.cluster["status"] in PRE_INSTALL:
            run(["bash", SCRIPT_DIR / "vm.sh", "create"], capture=False, timeout=1800)
            self.boot()
            run(["bash", SCRIPT_DIR / "manifests.sh", "prepare-manifests"], capture=False, timeout=1800)
        self.install()
        self.credentials()
        run(["bash", SCRIPT_DIR / "update-etc-hosts.sh"], capture=False)
        self.verify_nodes()
        run(["oc", "adm", "wait-for-stable-cluster", "--minimum-stable-period=2m", "--timeout=20m"], capture=False, timeout=1250)
        self.cleanup_media()

    def download(self):
        self.resolve()
        if self.cluster["status"] in PRE_INSTALL:
            self.prepare_infra()
            run(["bash", SCRIPT_DIR / "assisted-cluster.sh", "download"], data=self.image() + "\n", capture=False, timeout=1800)


def main():
    command = sys.argv[1]
    if command == "validate":
        validate(os.environ)
        return
    if command == "set-disk":
        set_exact_disk(*sys.argv[2:5])
        return
    installer = Installer()
    actions = {"run": installer.workflow, "create": installer.create, "install": installer.install,
               "preflight": lambda: (installer.resolve(absent=True), installer.preflight()),
               "boot": installer.boot, "eject-media": lambda: installer.cleanup_media(teardown="--teardown" in sys.argv[2:]),
               "network": lambda: installer.network(installer.directory / "network.yaml"),
               "status": installer.status, "verify": installer.verify_nodes, "kubeconfig": installer.credentials,
               "delete-cluster": installer.delete_cluster,
               "download-iso": installer.download,
               "cluster-id": lambda: print(installer.resolve()["id"]),
               "delete-worker": lambda: installer.delete_worker(sys.argv[2]),
               "installed": lambda: sys.exit(0 if installer.resolve()["status"] in INSTALLING | INSTALLED else 1)}
    if command not in actions:
        raise Error("Unknown day1-assisted command")
    # Read-only probes also run inside the parent orchestration's subprocesses.
    if command in {"installed", "cluster-id"}:
        actions[command]()
        return
    # Serialize lifecycle commands, including starts and media ownership writes.
    import fcntl
    installer.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (installer.directory / "lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise Error("Another day1-assisted lifecycle command is running") from exc
        actions[command]()


if __name__ == "__main__":
    try:
        main()
    except (Error, ValueError, KeyError, IndexError) as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        sys.exit(1)
