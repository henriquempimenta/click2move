"""Execute the workflow's actual upload shell steps against a fake curl."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest

from package import ROOT


def upload_step(name):
    workflow = (ROOT / ".github/workflows/publish.yml").read_text()
    step = workflow.split(f"      - name: {name}\n", 1)[1].split("      - name:", 1)[0]
    return textwrap.dedent(step.split("        run: |\n", 1)[1])


@unittest.skipUnless(shutil.which("jq"), "Workflow tests require jq")
class PublishTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        curl = self.root / "curl"
        curl.write_text("""#!/usr/bin/env python3
import os, pathlib, sys
pathlib.Path(sys.argv[sys.argv.index('--output') + 1]).write_text(os.environ['CURL_BODY'])
print(os.environ['CURL_STATUS'], end='')
""")
        curl.chmod(0o755)
        self.archive = self.root / "click2move_0.1.20016.zip"
        self.archive.write_bytes(b"test archive")
        self.key = "test-api-key-never-print"
        self.url = "https://upload.example.test/credential%0A-secret"
        self.output = self.root / "output"

    def run_step(self, name, body, status=200):
        env = os.environ | {
            "PATH": str(self.root) + os.pathsep + os.environ["PATH"],
            "CURL_BODY": json.dumps(body) if isinstance(body, dict) else body,
            "CURL_STATUS": str(status), "API_KEY": self.key, "MOD_NAME": "click2move",
            "UPLOAD_URL": self.url, "ZIP_FILE": str(self.archive),
            "SOURCE_URL": "https://example.test/source", "GITHUB_OUTPUT": str(self.output),
        }
        # Starting with tracing enabled verifies that each sensitive step disables it.
        return subprocess.run(["bash", "-x", "-c", upload_step(name)], env=env,
                              text=True, capture_output=True)

    def assert_no_credentials(self, result):
        self.assertNotIn(self.key, result.stdout + result.stderr)
        self.assertNotIn(self.url, result.stderr)

    def test_success_requires_portal_confirmation(self):
        result = self.run_step("Upload and finish release", {"success": True})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("uploaded successfully", result.stdout)
        self.assert_no_credentials(result)

    def test_http_error_does_not_log_body_or_credentials(self):
        result = self.run_step("Upload and finish release", {"error": self.url}, status=400)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(self.url, result.stdout + result.stderr)
        self.assert_no_credentials(result)

    def test_logical_failure_does_not_appear_successful(self):
        result = self.run_step("Upload and finish release", {"success": False, "error": self.url})
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("uploaded successfully", result.stdout)
        self.assertNotIn(self.url, result.stdout + result.stderr)

    def test_non_json_response_is_rejected_without_logging_it(self):
        result = self.run_step("Upload and finish release", self.url)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(self.url, result.stdout + result.stderr)

    def test_init_masks_encoded_url_before_setting_output(self):
        result = self.run_step("Initialize upload", {"upload_url": self.url})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "::add-mask::" + self.url.replace("%", "%25"))
        self.assertEqual(self.output.read_text(), f"upload_url={self.url}\n")
        self.assert_no_credentials(result)

    def test_init_http_failure_does_not_log_body(self):
        result = self.run_step("Initialize upload", {"upload_url": self.url}, status=403)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(self.url, result.stdout + result.stderr)

    def check_existing(self, releases, status=200):
        result = self.run_step("Check existing release", {"name": "click2move", "releases": releases}, status)
        published = self.output.read_text() if self.output.exists() else ""
        return result, published

    def release(self, version, content):
        return {"version": version, "sha1": hashlib.sha1(content).hexdigest()}

    def test_unpublished_version_is_uploaded(self):
        result, published = self.check_existing([self.release("0.1.21016", b"test archive")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(published, "published=false\n")

    def test_identical_published_release_is_skipped(self):
        result, published = self.check_existing([self.release("0.1.20016", b"test archive")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(published, "published=true\n")
        self.assertIn("identical contents", result.stdout)

    def test_different_published_release_is_a_conflict(self):
        result, published = self.check_existing([self.release("0.1.20016", b"other archive")])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(published, "")
        self.assertIn("different contents", result.stderr)

    def test_new_mod_is_uploaded(self):
        result, published = self.check_existing([], status=404)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(published, "published=false\n")

    def test_failed_or_malformed_lookup_stops_the_upload(self):
        for releases, status in (([], 500), ("not a list", 200), ([{"version": "0.1.20016"}], 200),
                                 ([self.release("0.1.20016", b"test archive")] * 2, 200)):
            with self.subTest(status=status, releases=releases):
                self.output.unlink(missing_ok=True)
                result, published = self.check_existing(releases, status)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(published, "")
        result = self.run_step("Check existing release", "not json")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
