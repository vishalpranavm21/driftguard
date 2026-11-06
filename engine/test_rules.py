"""Fixed-rule tests (stdlib only). Run:  cd engine && python -m unittest -v test_rules"""
import json
import unittest

from app import rules_score


def as_payload(dockerfile: str) -> str:
    # score_image() sends the Dockerfile inside json.dumps, so newlines arrive as a literal "\n"
    return json.dumps({"dockerfile": dockerfile})


class RootRule(unittest.TestCase):
    def test_eol_base_with_user_root_after_escaped_newline(self):
        r = rules_score(as_payload("FROM ubuntu:18.04\nUSER root"))
        self.assertEqual(r["risk_score"], 85)
        self.assertIn("container runs as root", r["reasons"])

    def test_user_root_alone_is_caught(self):
        # current base image: only the root rule can explain the 85
        r = rules_score(as_payload("FROM alpine:3.22\nUSER root"))
        self.assertEqual(r["risk_score"], 85)
        self.assertEqual(r["reasons"], ["container runs as root"])

    def test_non_root_user_is_not_flagged(self):
        r = rules_score(as_payload("FROM alpine:3.22\nUSER rootless\nUSER 101"))
        self.assertNotIn("container runs as root", r["reasons"])

    def test_risky_dockerfile_in_repo(self):
        with open("../app/Dockerfile.risky") as f:
            r = rules_score(as_payload(f.read()))
        self.assertIn("container runs as root", r["reasons"])


if __name__ == "__main__":
    unittest.main()
