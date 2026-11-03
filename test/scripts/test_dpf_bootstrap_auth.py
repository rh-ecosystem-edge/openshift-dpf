#!/usr/bin/env python3
"""Offline regression tests: python3 -m unittest discover -s test/scripts -v.

Extract only the functions under test: sourcing dpf.sh would load the real .env
and cluster utilities. Every oc invocation here is a shell-function mock.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "scripts/dpf.sh").read_text()
FUNCTION_NAMES = (
    "kube_apiserver_clusteroperator_condition_is",
    "kube_apiserver_clusteroperator_is_healthy",
    "apply_dpu_agent_bootstrap_auth",
    "apply_dpf",
)
FUNCTIONS = "\n".join(
    re.search(r"^function " + name + r"\(\) \{.*?^\}", SOURCE, re.M | re.S).group()
    for name in FUNCTION_NAMES
)
MOCKS = r'''
log() { printf '%s\n' "$*"; }
oc() {
    printf '%s\n' "$*" >> "$TRACE"
    case "$1 $2 $3" in
        "get kubeapiserver cluster")
            [ "${AUTH_GET_FAIL:-false}" != true ] || return 1
            printf '%s' "${BOOTSTRAP_ENABLED:-false}"
            ;;
        "patch kubeapiserver cluster") return "${PATCH_STATUS:-0}" ;;
        "get clusteroperator kube-apiserver")
            case "${4:-}" in
                -o)
                    case "$5" in
                        *Available*) printf '%s' "${AVAILABLE:-True}" ;;
                        *Progressing*) printf '%s' "${PROGRESSING:-False}" ;;
                        *Degraded*) printf '%s' "${DEGRADED:-False}" ;;
                        *) return 99 ;;
                    esac
                    ;;
                *) printf '%s\n' 'mock kube-apiserver status' ;;
            esac
            ;;
        "cluster-info  ") return 0 ;;
        "patch network.operator.openshift.io cluster") return 0 ;;
        *) printf 'Unexpected oc invocation: %s\n' "$*" >&2; return 99 ;;
    esac
}
retry() {
    printf 'retry %s\n' "$*" >> "$TRACE"
    shift 2
    if [ "$1" = kube_apiserver_clusteroperator_condition_is ]; then
        return "${START_STATUS:-0}"
    fi
    "$@"
}
get_kubeconfig() { :; }
deploy_argocd() { :; }
deploy_maintenance_operator() { :; }
deploy_nfd() { :; }
apply_namespaces() { :; }
deploy_cert_manager() { :; }
'''


class BootstrapAuthTests(unittest.TestCase):
    def run_shell(self, mode="host-trusted", command="apply_dpu_agent_bootstrap_auth", **overrides):
        with tempfile.TemporaryDirectory() as tmp:
            trace = Path(tmp) / "trace"
            trace.touch()
            env = {
                "PATH": os.defpath,
                "TRACE": str(trace),
                "MANIFESTS_DIR": str(ROOT / "manifests"),
                "DPF_DEPLOYMENT_MODE": mode,
                "DISABLE_NFD": "true",
                "KUBECONFIG": "/unused/mock-kubeconfig",
                # Stop apply_dpf after authentication, before Helm/credential work.
                "DPF_VERSION": "",
                **overrides,
            }
            result = subprocess.run(
                ["bash", "-c", "set -e; set -o pipefail\n" + FUNCTIONS + MOCKS + "\n" + command],
                env=env, capture_output=True, text=True,
            )
            return result, trace.read_text()

    def test_enables_bootstrap_auth_in_both_modes(self):
        for mode in ("host-trusted", "zero-trust"):
            with self.subTest(mode=mode):
                result, trace = self.run_shell(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(trace.count("patch kubeapiserver cluster"), 1)
                self.assertIn("--type=merge --patch-file " + str(ROOT / "manifests/dpf-installation/kube-apiserver-bootstrap-auth.patch.yaml"), trace)
                self.assertIn("retry 24 5 kube_apiserver_clusteroperator_condition_is Progressing True", trace)
                self.assertIn("retry 120 10 kube_apiserver_clusteroperator_is_healthy", trace)
                self.assertLess(trace.index("patch kubeapiserver"), trace.index("retry 120"))

    def test_already_enabled_skips_patch_but_checks_health(self):
        for mode in ("host-trusted", "zero-trust"):
            with self.subTest(mode=mode):
                result, trace = self.run_shell(mode, BOOTSTRAP_ENABLED="true")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("patch kubeapiserver", trace)
                self.assertNotIn("retry 24", trace)
                self.assertIn("retry 120", trace)

    def test_missing_patch_fails_without_mutation(self):
        result, trace = self.run_shell(MANIFESTS_DIR="/nonexistent/test-manifests")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("patch not found", result.stdout)
        self.assertNotIn("patch kubeapiserver", trace)
        self.assertNotIn("retry", trace)

    def test_patch_failure_stops_before_waiting(self):
        result, trace = self.run_shell(PATCH_STATUS="7")
        self.assertEqual(result.returncode, 7)
        self.assertNotIn("retry", trace)

    def test_unreadable_auth_setting_still_attempts_patch(self):
        result, trace = self.run_shell(AUTH_GET_FAIL="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("patch kubeapiserver", trace)

    def test_fast_rollout_requires_final_health(self):
        result, trace = self.run_shell(START_STATUS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("transition was not observed", result.stdout)
        self.assertIn("retry 120", trace)

    def test_unhealthy_api_server_fails(self):
        for condition, value in (("AVAILABLE", "False"), ("PROGRESSING", "True"), ("DEGRADED", "True")):
            with self.subTest(condition=condition):
                result, trace = self.run_shell(**{condition: value})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("rollout did not complete successfully", result.stdout)
                self.assertIn("get clusteroperator kube-apiserver\n", trace)
                self.assertNotIn("rollout is complete", result.stdout)

    def test_apply_dpf_invokes_auth_before_install_in_both_modes(self):
        for mode in ("host-trusted", "zero-trust"):
            with self.subTest(mode=mode):
                result, trace = self.run_shell(mode, command="apply_dpf")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("DPF_VERSION is not set", result.stdout)
                self.assertIn("patch kubeapiserver", trace)
                self.assertLess(result.stdout.index("rollout is complete"), result.stdout.index("Installing/upgrading DPF Operator"))

    def test_unhealthy_api_server_blocks_install(self):
        result, _ = self.run_shell(command="apply_dpf", DEGRADED="True")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Installing/upgrading DPF Operator", result.stdout)

    def test_shared_patch_is_unchanged(self):
        self.assertEqual(
            (ROOT / "manifests/dpf-installation/kube-apiserver-bootstrap-auth.patch.yaml").read_text(),
            'spec:\n  unsupportedConfigOverrides:\n    apiServerArguments:\n      enable-bootstrap-token-auth:\n        - "true"\n',
        )
        self.assertNotIn("apply_zero_trust_bootstrap_auth", SOURCE)
        self.assertNotIn("dpf-installation/zero-trust/kube-apiserver-bootstrap-auth", SOURCE)


if __name__ == "__main__":
    unittest.main()
