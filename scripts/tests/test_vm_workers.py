"""Offline checks: no cluster, credentials, or libvirt daemon required."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class VMWorkers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.env = dict(os.environ, TEST_TMP=str(self.path))

    def run_shell(self, body):
        return subprocess.run(["bash", "-c", 'source "$1/scripts/vm-workers.sh"\n' + body,
                               "test", str(ROOT)], env=self.env, text=True, capture_output=True)

    def test_local_access_preserves_backend(self):
        result = self.run_shell('unset CLUSTER_PROFILE_DIR\nLIBVIRT_HOST=existing\nworker_access\n[[ "$LIBVIRT_HOST" == existing ]]')
        self.assertEqual(result.returncode, 0, result.stderr)

    def profile(self, cluster="doca4"):
        profile = self.path / "profile"
        profile.mkdir()
        (profile / "cluster-name").write_text(cluster)
        (profile / "remote-host").write_text("hypervisor.example")
        (profile / "private-key").write_bytes(base64.b64encode(b"test-key"))
        self.env.update(CLUSTER_PROFILE_DIR=str(profile), CLUSTER_NAME="doca4", SHARED_DIR=str(self.path))
        (self.path / "kubeconfig").touch()
        bindir = self.path / "bin"
        bindir.mkdir()
        for name, code in {"ssh": '#!/bin/bash\nprintf test-token\n',
                           "oc": '#!/bin/bash\nprintf eyJhdXRocyI6e319\n'}.items():
            exe = bindir / name
            exe.write_text(code)
            exe.chmod(0o755)
        self.env["PATH"] = str(bindir) + os.pathsep + self.env["PATH"]

    def test_prow_access_and_secret_cleanup(self):
        self.profile()
        result = self.run_shell('trap worker_exit EXIT\naction=add\nrepository_dir="$TEST_TMP"\nworker_access\n'
                                '[[ "$LIBVIRT_HOST" == root@hypervisor.example ]]\n'
                                '[[ "$(cat "$AICLI_HOME/.aicli/offlinetoken.txt")" == test-token ]]\n'
                                '[[ "$(cat "$OPENSHIFT_PULL_SECRET")" == \'{"auths":{}}\' ]]\n'
                                'printf "%s" "$worker_access_dir"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path(result.stdout).exists())
        self.assertNotIn("test-token", result.stdout + result.stderr)

    def test_wrong_profile_fails_before_access(self):
        self.profile("another-cluster")
        result = self.run_shell('action=add\nrepository_dir="$TEST_TMP"\nworker_access')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)

    def test_failed_create_stops_installation(self):
        result = self.run_shell('worker_create() { return 7; }\nretry() { touch "$TEST_TMP/installed"; }\nworker_add')
        self.assertEqual(result.returncode, 7)
        self.assertFalse((self.path / "installed").exists())

    def cleanup_fixture(self, owned_cluster=True):
        state = self.path / "state"
        state.mkdir()
        (state / "infraenv").write_text("own-infra")
        if owned_cluster:
            (state / "created-cluster").write_text("own-cluster")
        (self.path / "clusters-cleanup").write_text('[{"name":"doca4-day2","id":"own-cluster"}]')
        return '''
log() { :; }
delete_worker_vms() { :; }
libvirt_host_cmd() { printf '%s\\n' "$*" >> "$TEST_TMP/commands"; }
worker_state="$TEST_TMP/state"
worker_infraenv=own
ISO_PATH=/images/own.iso
day2_cluster=doca4-day2
aicli() {
    printf '%s\\n' "$*" >> "$TEST_TMP/commands"
    case "$*" in
      '-o json list infraenvs') cat "$TEST_TMP/infraenvs" ;;
      '-o json list clusters') cat "$TEST_TMP/clusters-cleanup" ;;
      'delete infraenv own-infra --force -y') printf '[]' > "$TEST_TMP/infraenvs" ;;
      'delete cluster own-cluster -y') printf '[]' > "$TEST_TMP/clusters-cleanup" ;;
    esac
}
'''

    def test_cleanup_preserves_preexisting_day2_record(self):
        body = self.cleanup_fixture(owned_cluster=False)
        (self.path / "infraenvs").write_text('[{"name":"own","id":"own-infra"}]')
        result = self.run_shell(body + '\nworker_delete')
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = (self.path / "commands").read_text()
        self.assertIn('delete infraenv own-infra --force -y', commands)
        self.assertNotIn('delete cluster', commands)

    def test_cleanup_removes_owned_day2_record(self):
        body = self.cleanup_fixture()
        (self.path / "infraenvs").write_text('[{"name":"own","id":"own-infra","cluster_id":"own-cluster"}]')
        result = self.run_shell(body + '\nworker_delete')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('delete cluster own-cluster -y', (self.path / "commands").read_text())
        self.assertFalse((self.path / "state").exists())

    def test_cleanup_failure_retains_ownership(self):
        body = self.cleanup_fixture()
        result = self.run_shell(body + '\naicli() { return 9; }\nworker_delete')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.path / "state/infraenv").exists())

    def test_cleanup_refuses_changed_identity(self):
        body = self.cleanup_fixture()
        (self.path / "infraenvs").write_text('[{"name":"own","id":"someone-else"}]')
        result = self.run_shell(body + '\nworker_delete')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('delete infraenv', (self.path / "commands").read_text())

    def test_host_installation_is_scoped_to_infraenv(self):
        source = (ROOT / "scripts/cluster.sh").read_text()
        function = source[source.index('function install_day2_hosts()'):]
        function = function[:function.index('\n}\n') + 3]
        hosts = [dict(id="ours", infra_env_id="owned", cluster_id="cluster", status="known"),
                 dict(id="unrelated", infra_env_id="other", cluster_id="cluster", status="known"),
                 dict(id="other-installed", infra_env_id="other", cluster_id="cluster", status="installed")]
        (self.path / "hosts").write_text(json.dumps(hosts))
        (self.path / "aicli").write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ['TEST_TMP'])
a = sys.argv[1:]
if a == ['-o', 'json', 'list', 'hosts']: print((p/'hosts').read_text())
elif a[:2] == ['start', 'host']:
 with (p/'started').open('a') as f: f.write(a[2]+'\\n')
 hosts=json.loads((p/'hosts').read_text())
 for h in hosts:
  if h['id']==a[2]: h['status']='installed'
 (p/'hosts').write_text(json.dumps(hosts))
''')
        (self.path / "aicli").chmod(0o755)
        body = function + '''
log() { :; }
retry() { shift 2; "$@"; }
get_day2_cluster_id() { echo cluster; }
get_infra_env_id() { echo owned; }
aicli() { "$TEST_TMP/aicli" "$@"; }
VM_WORKER_COUNT=1 CLUSTER_NAME=doca4-day2 install_day2_hosts owned 1
'''
        result = self.run_shell(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.path / "started").read_text(), "ours\n")

    def test_csr_approval_checks_subject_requester_and_denial(self):
        def request(node):
            key, req = self.path / (node + ".key"), self.path / (node + ".pem")
            subprocess.run(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
                            "-keyout", str(key), "-out", str(req), "-subj",
                            "/O=system:nodes/CN=system:node:" + node],
                           check=True, capture_output=True)
            return base64.b64encode(req.read_bytes()).decode()
        own, other = request("temporary-1"), request("another-worker")
        bootstrap = "system:serviceaccount:openshift-machine-config-operator:node-bootstrapper"
        def csr(name, pem, user=bootstrap, signer="kubernetes.io/kube-apiserver-client-kubelet", denied=False):
            return {"metadata": {"name": name}, "spec": {"request": pem, "username": user, "signerName": signer},
                    "status": {"conditions": [{"type": "Denied"}]} if denied else {}}
        requests = [csr("our-client", own), csr("other", other),
                    csr("our-serving", own, "system:node:temporary-1", "kubernetes.io/kubelet-serving"),
                    csr("wrong-user", own, "someone-else"), csr("denied", own, denied=True),
                    csr("wrong-signer", own, signer="example.com/other"), csr("malformed", "not-pem")]
        (self.path / "requests").write_text(json.dumps({"items": requests}))
        result = self.run_shell('''
worker_state="$TEST_TMP" VM_WORKER_COUNT=1 VM_WORKER_PREFIX=temporary-
oc() {
    if [ "$1" = get ]; then cat "$TEST_TMP/requests"
    else printf '%s\\n' "$4" >> "$TEST_TMP/approved"; fi
}
worker_approve_csrs
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.path / "approved").read_text().splitlines(), ["our-client", "our-serving"])

    def test_libvirt_list_failure_is_not_successful_cleanup(self):
        source = (ROOT / "scripts/vm.sh").read_text()
        function = source[source.index('_delete_vms_by_prefix()'):]
        function = function[:function.index('\n}\n') + 3]
        result = self.run_shell(function + '''
log() { :; }
lvirsh() { return 9; }
_delete_vms_by_prefix temporary-
''')
        self.assertNotEqual(result.returncode, 0)

    def test_create_uses_separate_day2_record_and_reuses_owned_infraenv(self):
        (self.path / "pull-secret").write_text('{"auths":{}}')
        (self.path / "public-key").write_text("test-public-key")
        (self.path / "clusters").write_text('[{"id":"base-id","name":"doca4","status":"installed"}]')
        (self.path / "infraenvs").write_text('[]')
        fake = self.path / "aicli"
        fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ['TEST_TMP'])
a = sys.argv[1:]
with (p/'commands').open('a') as f: f.write(' '.join(a)+'\\n')
clusters=json.loads((p/'clusters').read_text())
infraenvs=json.loads((p/'infraenvs').read_text())
if a == ['-o','json','list','clusters']: print(json.dumps(clusters))
elif a == ['-o','json','list','infraenvs']: print(json.dumps(infraenvs))
elif a[:4] == ['-o','json','info','cluster']:
 print(json.dumps(next(x for x in clusters if a[4] in (x['name'], x['id']))))
elif a[:2] == ['create','cluster']:
 clusters.append(dict(id='day2-id',name=a[2],status='adding-hosts',openshift_cluster_id='base-id'))
 (p/'clusters').write_text(json.dumps(clusters))
elif a[:2] == ['create','infraenv']:
 infraenvs.append(dict(id='infra-id',name=a[2],cluster_id='day2-id'))
 (p/'infraenvs').write_text(json.dumps(infraenvs))
else: sys.exit(11)
''')
        fake.chmod(0o755)
        body = '''
unset CLUSTER_PROFILE_DIR
log() { :; }
aicli() { "$TEST_TMP/aicli" "$@"; }
lvirsh() { :; }
libvirt_host_cmd() { :; }
arch_for_aicli() { echo x86_64; }
get_iso() { printf '%s\\n' "$1" >> "$TEST_TMP/isos"; }
create_worker_vms() { touch "$TEST_TMP/vm-created"; }
CLUSTER_NAME=doca4 VM_WORKER_PREFIX=temporary- VM_WORKER_COUNT=1 VM_COUNT=3
GENERATED_DIR="$TEST_TMP/generated" ISO_FOLDER=/images BRIDGE_NAME=br0
OPENSHIFT_PULL_SECRET="$TEST_TMP/pull-secret" SSH_KEY="$TEST_TMP/public-key"
OPENSHIFT_VERSION=4.22 NODES_MTU=1500 ARCH=x86_64
worker_names
worker_create
worker_create
'''
        result = self.run_shell(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = (self.path / "commands").read_text()
        self.assertEqual(commands.count('create cluster doca4-day2'), 1)
        self.assertEqual(commands.count('create infraenv'), 1)
        self.assertNotIn('update cluster', commands)
        self.assertTrue((self.path / "vm-created").exists())

    def test_remote_libvirt_and_host_commands_share_identity(self):
        source = (ROOT / "scripts/utils.sh").read_text()
        functions = source[source.index('libvirt_uri()'):source.index('# Map uname -m')]
        result = self.run_shell(functions + '''
LIBVIRT_HOST=root@hypervisor.example LIBVIRT_SSH_KEY=/tmp/worker-key
[[ "$(libvirt_uri)" == 'qemu+ssh://root@hypervisor.example/system?keyfile=/tmp/worker-key&no_verify=1&no_tty=1' ]]
ssh() { printf '%s\\n' "$@" > "$TEST_TMP/ssh-args"; }
libvirt_host_cmd ip link show br0
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.path / "ssh-args").read_text().splitlines()
        self.assertIn('/tmp/worker-key', args)
        self.assertIn('root@hypervisor.example', args)
        self.assertEqual(args[-1], 'ip link show br0 ')

    def test_full_cleanup_retains_records_after_worker_cleanup_failure(self):
        source = (ROOT / "scripts/cleanup.sh").read_text()
        function = source[source.index('clean_all()'):]
        function = function[:function.index('\n}\n') + 3]
        (self.path / "vm-workers.sh").write_text('exit 5\n')
        result = self.run_shell(function + '''
log() { :; }
SCRIPT_DIR="$TEST_TMP"
clean_all
''')
        self.assertEqual(result.returncode, 5)


if __name__ == "__main__":
    unittest.main()
