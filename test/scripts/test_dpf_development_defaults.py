#!/usr/bin/env python3
"""Offline checks for the coordinated custom-stack defaults and overrides."""
import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
EXPECTED = {
    "DPF_VERSION": "26.11.0-jsonfix.50d5103.1",
    "DPF_HELM_REPO_URL": "oci://quay.io/itsoiref",
    "DPF_HCP_PROVISIONER_OPERATOR_CHART_URL": "oci://quay.io/redhat-user-workloads/dpu-kit-for-nvidia-operator-tenant/chart",
    "DPF_HCP_PROVISIONER_OPERATOR_VERSION": "0.1.398+a2ea697",
    "DPF_HCP_PROVISIONER_OPERATOR_IMAGE_REPO": "quay.io/itsoiref/dpf-hcp-provisioner-operator",
    "DPF_HCP_PROVISIONER_OPERATOR_IMAGE_TAG": "pr334-pr348-pr350-pr352-a2ea697d-v1",
}


class DevelopmentDefaultsTests(unittest.TestCase):
    def defaults(self, overrides=None):
        # Source only canonical defaults, never .env or cluster utilities.
        result = subprocess.run(
            ["bash", "-ec", 'source "$1"; shift; for key; do printf "%s=%s\\n" "$key" "${!key}"; done',
             "defaults-test", str(ROOT / "ci/env.defaults"), *EXPECTED],
            env={"PATH": os.defpath, **(overrides or {})},
            capture_output=True, text=True, check=True,
        )
        return dict(line.split("=", 1) for line in result.stdout.splitlines())

    def test_complete_custom_stack_selected_by_default(self):
        self.assertEqual(self.defaults(), EXPECTED)

    def test_explicit_configuration_takes_precedence(self):
        overrides = {key: "explicit-" + key.lower() for key in EXPECTED}
        self.assertEqual(self.defaults(overrides), overrides)


if __name__ == "__main__":
    unittest.main()
