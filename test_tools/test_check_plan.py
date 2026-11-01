"""Check classification regressions; no Nix execution or host state required."""
import copy
import json
import unittest

from check_plan import ROOT, REQUIRED_NATIVE, declared_checks, plan


class CheckPlan(unittest.TestCase):
    def setUp(self):
        self.policy = {"version": 1, "native": ["build"], "evaluation": ["eval"], "vm": ["boot"]}
        self.declared = ["build", "eval", "boot"]

    def test_only_native_and_available_checks_are_built(self):
        self.assertEqual(plan(self.policy, self.declared, self.declared), ["build"])
        with self.assertRaises(ValueError):
            plan(self.policy, self.declared, ["eval", "boot"])

    def test_required_checks_cannot_disappear_or_be_reclassified(self):
        with self.assertRaises(ValueError):
            plan(self.policy, self.declared, self.declared, {"eval"})
        policy = json.loads((ROOT / "test_tools/check-policy.json").read_text())
        declared = declared_checks(ROOT)
        for required in REQUIRED_NATIVE:
            with self.subTest(required=required), self.assertRaises(ValueError):
                plan(policy, declared, [name for name in declared if name != required], REQUIRED_NATIVE)

    def test_new_stale_duplicate_and_unknown_checks_fail(self):
        for declared, available in [(self.declared + ["new"], self.declared),
                                    (["eval", "boot"], ["eval", "boot"]),
                                    (self.declared, ["unknown"]), (self.declared, []),
                                    (self.declared, ["build", "build"])]:
            with self.subTest(declared=declared, available=available), self.assertRaises(ValueError):
                plan(self.policy, declared, available)
        self.policy["vm"].append("build")
        with self.assertRaises(ValueError):
            plan(self.policy, self.declared, self.declared)

    def test_schema_and_shell_metacharacters_are_rejected(self):
        for update in ({"version": True}, {"extra": []}, {"native": "build"},
                       {"native": ["build", "build"]}, {"native": ["a;command"]}):
            with self.subTest(update=update), self.assertRaises(ValueError):
                plan(copy.deepcopy(self.policy) | update, self.declared, self.declared)

    def test_repository_policy_is_complete_and_keeps_runtime_checks(self):
        policy = json.loads((ROOT / "test_tools/check-policy.json").read_text())
        declared = declared_checks(ROOT)
        builds = plan(policy, declared, declared, REQUIRED_NATIVE)
        for name in ("gnupg", "home-manager-integration", "desktop-policy", "ci-check-plan"):
            self.assertIn(name, builds)
        self.assertNotIn("ssh-certificate-boot", builds)


if __name__ == "__main__":
    unittest.main()
