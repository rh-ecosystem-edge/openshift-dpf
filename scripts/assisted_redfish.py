"""Redfish discovery boot with private requests and owned cleanup.

No authentication material or download URL is persisted in lifecycle records.
Resource/action URLs come from the BMC and are constrained to its own origin.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from urllib.parse import urljoin, urlsplit

from assisted_install import Error, iso_url, log, mac, require, workers


class RequestRejected(Error):
    """The BMC rejected a write before accepting an asynchronous operation."""


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def curl_quote(value):
    if any(c in value for c in "\r\n\x00"):
        raise Error("Redfish request value contains a forbidden control character")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


class Redfish:
    """Standard Redfish boot backend; all resource/action URLs are discovered."""

    method = "redfish-virtualmedia"

    @staticmethod
    def validate_config(env):
        require(env.get("REDFISH_INSECURE", "false") in {"true", "false"}, "REDFISH_INSECURE must be true or false")
        ca = env.get("REDFISH_CA_BUNDLE", "")
        if ca and (env.get("REDFISH_INSECURE") == "true" or not os.path.isfile(ca) or not os.access(ca, os.R_OK)):
            raise Error("REDFISH_CA_BUNDLE must be readable and cannot be combined with REDFISH_INSECURE=true")
        bmcs = []
        for worker in workers(env):
            key = f"WORKER_{worker['index']}_"
            for field in ("BMC_IP", "BMC_USER", "BMC_PASSWORD"):
                require(env.get(key + field), f"{key}{field} is required")
                require(not any(c in env[key + field] for c in "\r\n\x00"), f"{key}{field} contains unsupported control characters")
            bmc = env[key + "BMC_IP"].lower()
            require(re.fullmatch(r"[a-z0-9.:-]+", bmc),
                    f"{key}BMC_IP must be an address or hostname, without a URL or credentials")
            system = env.get(key + "REDFISH_SYSTEM_PATH", "")
            require(not system or re.fullmatch(r"/redfish/v1/Systems/[a-zA-Z0-9_.~-]+", system),
                    f"{key}REDFISH_SYSTEM_PATH must identify one Redfish system")
            media_path = env.get(key + "REDFISH_VIRTUAL_MEDIA_PATH", "")
            if media_path and not re.fullmatch(
                    r"/redfish/v1/(?:Systems|Managers)/[a-zA-Z0-9_.~-]+/VirtualMedia/[a-zA-Z0-9_.~-]+", media_path):
                raise Error(f"{key}REDFISH_VIRTUAL_MEDIA_PATH must identify one Redfish virtual-media device")
            if any(b == bmc and (not s or not system or s == system) for b, s in bmcs):
                raise Error(f"{key}BMC_IP/system selection is ambiguous or duplicated")
            bmcs.append((bmc, system))

    def __init__(self, env, worker):
        self.env, self.worker = env, worker
        self.prefix = f"WORKER_{worker['index']}_"
        address = env[self.prefix + "BMC_IP"]
        if address.count(":") > 1 and not address.startswith("["):
            address = f"[{address}]"
        self.base = "https://" + address

    def local_path(self, value):
        resolved = urlsplit(urljoin(self.base, value))
        if (resolved.scheme != "https" or resolved.netloc != urlsplit(self.base).netloc or
                not resolved.path.startswith("/redfish/v1/") or resolved.query or resolved.fragment):
            raise Error(f"{self.worker['name']}: BMC supplied an unsafe Redfish resource URL")
        return resolved.path

    def request(self, method, path, body=None, *, task=True):
        path = self.local_path(path)
        with tempfile.TemporaryDirectory(prefix="assisted-redfish-") as directory:
            headers = Path(directory) / "headers"
            lines = ["silent", "show-error", "connect-timeout = 10", "max-time = 60",
                     "proto = \"=https\"", "request = " + curl_quote(method),
                     "url = " + curl_quote(self.base + path),
                     "user = " + curl_quote(self.env[self.prefix + "BMC_USER"] + ":" + self.env[self.prefix + "BMC_PASSWORD"]),
                     "header = \"Content-Type: application/json\""]
            if self.env.get("REDFISH_INSECURE", "false") == "true":
                lines.append("insecure")
            elif self.env.get("REDFISH_CA_BUNDLE"):
                lines.append("cacert = " + curl_quote(self.env["REDFISH_CA_BUNDLE"]))
            if body is not None:
                lines.append("data-binary = " + curl_quote(json.dumps(body)))
            # Retrying a lost POST response can reboot twice or insert media twice.
            attempts = 3 if method == "GET" else 1
            for attempt in range(attempts):
                try:
                    result = subprocess.run(["curl", "--disable", "--config", "-", "--dump-header", str(headers),
                                             "--write-out", "\n%{http_code}"], input="\n".join(lines) + "\n",
                                            capture_output=True, text=True, timeout=65, check=False)
                except (OSError, subprocess.TimeoutExpired) as exc:
                    raise Error(f"{self.worker['name']}: Redfish {method} request unavailable/timed out") from exc
                payload, _, status = result.stdout.rpartition("\n")
                code = int(status) if status.isdigit() else 0
                if result.returncode == 0 and 200 <= code < 300:
                    break
                if method == "GET" and (code in {0, 429, 500, 502, 503, 504}) and attempt + 1 < attempts:
                    time.sleep(2)
                    continue
                error = RequestRejected if (method != "GET" and result.returncode == 0 and
                                            400 <= code < 500 and code != 408) else Error
                raise error(f"{self.worker['name']}: Redfish {method} failed (HTTP {code}, curl {result.returncode}); "
                            "check authentication, TLS, capabilities, or BMC task diagnostics")
            value = json.loads(payload) if payload.strip() else {}
            if not task:
                return code, value
            if code == 202 and task:
                location = next((line.split(":", 1)[1].strip() for line in headers.read_text().splitlines()
                                 if line.lower().startswith("location:")), None)
                if not location:
                    raise Error(f"{self.worker['name']}: asynchronous Redfish operation has no task Location")
                self.wait_task(location)
            return value

    def wait_task(self, path):
        path = self.local_path(path)
        deadline = time.monotonic() + 300
        for _ in range(60):
            if time.monotonic() >= deadline:
                break
            code, value = self.request("GET", path, task=False)
            state, status = value.get("TaskState"), value.get("TaskStatus")
            if state == "Completed" and status in {None, "OK"}:
                return
            if state in {"Exception", "Killed", "Cancelled", "Interrupted", "Suspended"} or status in {"Critical", "Warning"}:
                raise Error(f"{self.worker['name']}: Redfish task failed ({state}/{status})")
            if code != 202 and state is None:
                return  # A completed TaskMonitor returns the original operation's response.
            time.sleep(5)
        raise Error(f"{self.worker['name']}: Redfish task did not complete within the retry budget")

    def members(self, path):
        return [self.local_path(m["@odata.id"]) for m in self.request("GET", path).get("Members", [])]

    def discover(self, record=None):
        systems = self.members("/redfish/v1/Systems")
        selected = self.env.get(self.prefix + "REDFISH_SYSTEM_PATH")
        if not selected:
            require(len(systems) == 1, f"{self.worker['name']}: ambiguous Redfish Systems; set REDFISH_SYSTEM_PATH")
            selected = systems[0]
        require(selected in systems, f"{self.worker['name']}: configured Redfish system is not in Systems")
        system = self.request("GET", selected)
        boot = system.get("Boot", {})
        require("Cd" in boot.get("BootSourceOverrideTarget@Redfish.AllowableValues", []),
                f"{self.worker['name']}: system does not advertise virtual CD boot")
        if "Once" not in boot.get("BootSourceOverrideEnabled@Redfish.AllowableValues", ["Once", "Disabled"]):
            raise Error(f"{self.worker['name']}: one-time boot is unsupported")
        reset = system.get("Actions", {}).get("#ComputerSystem.Reset", {})
        require(reset.get("target"), f"{self.worker['name']}: system has no reset action")
        reset_types = reset.get("ResetType@Redfish.AllowableValues", [])
        if "On" not in reset_types or not any(t in reset_types for t in ("GracefulRestart", "ForceRestart")):
            raise Error(f"{self.worker['name']}: required power-on/restart operations are not advertised")
        collections = []
        if system.get("VirtualMedia"):
            collections.append(system["VirtualMedia"]["@odata.id"])
        for manager in system.get("Links", {}).get("ManagedBy", []):
            value = self.request("GET", manager["@odata.id"])
            if value.get("VirtualMedia"):
                collections.append(value["VirtualMedia"]["@odata.id"])
        candidates = {}
        for collection in set(collections):
            for path in self.members(collection):
                media = self.request("GET", path)
                actions = media.get("Actions", {})
                insert = actions.get("#VirtualMedia.InsertMedia", {}).get("target")
                eject = actions.get("#VirtualMedia.EjectMedia", {}).get("target")
                if any(t in media.get("MediaTypes", []) for t in ("CD", "DVD")) and insert and eject:
                    candidates[path] = {"media": path, "insert": self.local_path(insert), "eject": self.local_path(eject)}
        # Newer iDRACs expose two system slots alongside the legacy manager
        # CD endpoint. Do not guess which slot to use or assume they are aliases.
        # Reuse the pinned endpoint on subsequent runs and during owned cleanup.
        media_path = self.env.get(self.prefix + "REDFISH_VIRTUAL_MEDIA_PATH") or (record or {}).get("media")
        if not media_path:
            require(len(candidates) == 1,
                    f"{self.worker['name']}: found {len(candidates)} usable virtual CD/DVD devices; "
                    f"set {self.prefix}REDFISH_VIRTUAL_MEDIA_PATH to one of: "
                    + (", ".join(sorted(candidates)) or "none (BMC virtual media support is required)"))
            media_path = next(iter(candidates))
        media_path = self.local_path(media_path)
        require(media_path in candidates, f"{self.worker['name']}: selected virtual media is not a usable CD/DVD device "
                                         "linked to the selected system")
        return {**candidates[media_path], "system": selected,
                "reset": self.local_path(reset["target"]), "reset_types": reset_types}

    def check_record(self, resources, record):
        if record and (record.get("mac") != mac(self.worker["mac"]) or
                       record.get("bmc") != self.base or record.get("system") != resources["system"] or
                       record.get("media") != resources["media"]):
            raise Error(f"{self.worker['name']}: persisted media ownership does not match the live system")

    def check_media(self, resources, record):
        self.check_record(resources, record)
        media = self.request("GET", resources["media"])
        if media.get("Inserted") or media.get("Image"):
            if not record or digest(media.get("Image", "")) != record.get("image_sha256"):
                raise Error(f"{self.worker['name']}: unrelated or changed virtual media; refusing replacement/ejection")
        boot = self.request("GET", resources["system"]).get("Boot", {})
        if boot.get("BootSourceOverrideEnabled", "Disabled") != "Disabled":
            if (not record or not record.get("override_owned") or boot.get("BootSourceOverrideTarget") != "Cd" or
                    boot.get("BootSourceOverrideEnabled") != "Once"):
                raise Error(f"{self.worker['name']}: an unrelated boot override is active")
        return media, boot

    def clear_override(self, resources, record):
        media, boot = self.check_media(resources, record)
        if boot.get("BootSourceOverrideEnabled", "Disabled") != "Disabled":
            self.request("PATCH", resources["system"], {"Boot": {"BootSourceOverrideEnabled": "Disabled"}})
        return media

    def preflight(self, record=None):
        resources = self.discover(record)
        self.check_media(resources, record)
        return self.base, resources["system"]

    def boot(self, image, record, save):
        image = iso_url(image)
        resources = self.discover(record)
        media, _ = self.check_media(resources, record)
        if record and record.get("boot_requested"):
            if not record.get("boot_confirmed"):
                raise Error(f"{self.worker['name']}: reset outcome is uncertain; inspect BMC/discovery state or "
                            "perform explicit teardown before retrying. No second reset was sent.")
            log(f"{self.worker['name']}: discovery boot already requested; waiting without another reboot")
            return
        if not record:
            record = {"boot_method": self.method, "mac": mac(self.worker["mac"]), "bmc": self.base,
                      "system": resources["system"], "media": resources["media"], "image_sha256": digest(image),
                      "override_owned": False, "boot_requested": False}
            save(record)  # Save before insertion so interrupted operations can be reconciled.
        if not media.get("Inserted"):
            record["image_sha256"] = digest(image)
            save(record)
            self.request("POST", resources["insert"], {"Image": image, "Inserted": True, "WriteProtected": True})
            for _ in range(30):
                media = self.request("GET", resources["media"])
                if media.get("Inserted") and digest(media.get("Image", "")) == record["image_sha256"]:
                    break
                time.sleep(2)
            else:
                raise Error(f"{self.worker['name']}: discovery image was not inserted; verify BMC download access")
        record["override_owned"] = True
        save(record)
        try:
            self.request("PATCH", resources["system"], {"Boot": {"BootSourceOverrideEnabled": "Once", "BootSourceOverrideTarget": "Cd"}})
            system = self.request("GET", resources["system"])
            boot = system.get("Boot", {})
            if boot.get("BootSourceOverrideEnabled") != "Once" or boot.get("BootSourceOverrideTarget") != "Cd":
                raise Error(f"{self.worker['name']}: BMC did not accept the one-time CD boot override")
            reset_type = "On" if system.get("PowerState") == "Off" else next(
                t for t in ("GracefulRestart", "ForceRestart") if t in resources["reset_types"])
            record["boot_requested"] = True
            record["boot_confirmed"] = False
            save(record)  # Lost reset responses must not cause a second reboot.
            try:
                self.request("POST", resources["reset"], {"ResetType": reset_type})
            except RequestRejected:
                record["boot_requested"] = False
                save(record)
                raise
            record["boot_confirmed"] = True
            save(record)
        except Error as exc:
            if record.get("boot_requested"):
                raise Error(f"{self.worker['name']}: reset outcome is uncertain; preserving discovery media and "
                            "one-time boot. Inspect BMC/discovery state before resuming; no automatic reset retry.") from exc
            # No reset was accepted. Clear only an override that still matches ours.
            try:
                self.clear_override(resources, record)
            except Error:
                log(f"{self.worker['name']}: could not clear owned boot override; inspect BMC state before resuming")
            raise

    def cleanup(self, record):
        resources = self.discover(record)
        media = self.clear_override(resources, record)
        if media.get("Inserted") or media.get("Image"):
            self.request("POST", resources["eject"], {})
            for _ in range(30):
                media = self.request("GET", resources["media"])
                if not media.get("Inserted") and not media.get("Image"):
                    log(f"{self.worker['name']}: owned discovery media ejected")
                    return
                time.sleep(2)
            raise Error(f"{self.worker['name']}: media ejection did not complete")
