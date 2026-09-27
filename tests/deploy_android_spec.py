"""Isolated deployment checks: python tests/deploy_android_spec.py (requires sh)."""

from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
SHELL = shutil.which("sh")
SCRIPT = REPOSITORY / "scripts" / "sync-android.sh"


def shell_path(path):
    value = path.resolve().as_posix()
    if os.name == "nt" and len(value) > 1 and value[1] == ":":
        return "/" + value[0].lower() + value[2:]
    return value


@unittest.skipUnless(SHELL, "sh is required; Git for Windows includes it")
class AndroidDeploymentTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix=".deploy-test-", dir=REPOSITORY))
        self.payload = self.root / "payload"
        self.plugins = self.root / "device with space and 'quote" / "plugins"
        self.target = self.plugins / "AI_Dictionary.koplugin"
        self.plugins.mkdir(parents=True)
        self.write(self.payload, "main.lua", "new main")
        self.write(self.payload, "_meta.lua", "new metadata")

    def tearDown(self):
        # Check the resolved target before recursive removal on Windows too.
        resolved = self.root.resolve()
        if resolved.parent != REPOSITORY or not resolved.name.startswith(".deploy-test-"):
            raise RuntimeError("Unexpected test cleanup path")
        shutil.rmtree(resolved)

    def write(self, root, relative, contents):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        return path

    def deploy(self, expected_success=True, payload=None, plugins=None):
        result = subprocess.run(
            [SHELL, shell_path(SCRIPT), shell_path(payload or self.payload),
             shell_path(plugins or self.plugins)],
            capture_output=True, text=True, encoding="utf-8",
        )
        if expected_success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_updates_and_prunes_while_preserving_user_data(self):
        protected = [
            "configuration.lua", "nested/configuration.lua",
            "Lookups/Lookups.txt", "Lookups/subdir/old.lua",
            "Lookups/.hidden", ".update-working/old.lua", ".update-lock",
        ]
        snapshots = {}
        for relative in protected:
            path = self.write(self.target, relative, "device data: " + relative)
            snapshots[relative] = (path.read_bytes(), path.stat().st_mtime_ns)
        (self.target / "Lookups/empty").mkdir()
        (self.target / ".update-empty").mkdir()
        stale = [
            "old-name.lua", "nested/obsolete.lua", "removed-dir/old.lua",
            ".hidden-stale", "Audio/cache.mp3", "old file's name.lua",
        ]
        for relative in stale:
            self.write(self.target, relative, "obsolete")
        self.write(self.target, "main.lua", "old main")
        self.write(self.payload, "new-name.lua", "new module")
        self.write(self.payload, "Resources/asset with 'quote.dex", "new asset")
        # Only root Lookups and .update-* directories are protected.
        self.write(self.payload, "Resources/Lookups/current.lua", "current")
        self.write(self.target, "Resources/Lookups/obsolete.lua", "obsolete")
        self.write(self.target, "Resources/.update-obsolete/old.lua", "obsolete")
        sibling = self.write(self.plugins, "Other.koplugin/old.lua", "other plugin")

        self.deploy()

        for relative, snapshot in snapshots.items():
            path = self.target / relative
            self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), snapshot)
        for relative in stale + ["Resources/Lookups/obsolete.lua"]:
            self.assertFalse((self.target / relative).exists(), relative)
        for relative in ["removed-dir", "Audio", "Resources/.update-obsolete"]:
            self.assertFalse((self.target / relative).exists(), relative)
        self.assertTrue((self.target / "Lookups/empty").is_dir())
        self.assertTrue((self.target / ".update-empty").is_dir())
        for path in self.payload.rglob("*"):
            if path.is_file():
                self.assertEqual((self.target / path.relative_to(self.payload)).read_bytes(), path.read_bytes())
        self.assertEqual(sibling.read_text(), "other plugin")

    def test_first_install_and_repeat_deployment(self):
        self.deploy()
        self.deploy()
        self.assertEqual((self.target / "main.lua").read_text(), "new main")
        self.assertFalse((self.target / "configuration.lua").exists())
        self.assertFalse((self.target / "Lookups").exists())

    def test_incomplete_payload_leaves_installation_unchanged(self):
        (self.payload / "_meta.lua").unlink()
        stale = self.write(self.target, "stale.lua", "keep until a successful deployment")
        main = self.write(self.target, "main.lua", "old main")
        self.deploy(expected_success=False)
        self.assertTrue(stale.exists())
        self.assertEqual(main.read_text(), "old main")

    def test_payload_cannot_overwrite_protected_files(self):
        for relative in ["configuration.lua", "nested/configuration.lua", "Lookups/log.txt", ".update-lock"]:
            with self.subTest(relative=relative):
                protected = self.write(self.target, relative, "device data")
                invalid = self.write(self.payload, relative, "local data")
                main = self.write(self.target, "main.lua", "old main")
                self.deploy(expected_success=False)
                self.assertEqual(protected.read_text(), "device data")
                self.assertEqual(main.read_text(), "old main")
                invalid.unlink()
                # Remove fixture-only empty parents from the payload.
                parent = invalid.parent
                while parent != self.payload:
                    parent.rmdir()
                    parent = parent.parent

    def test_copy_failure_does_not_prune(self):
        # cp cannot overwrite this directory with the payload's main.lua file.
        self.write(self.target, "main.lua/contents.txt", "directory conflict")
        stale = self.write(self.target, "stale.lua", "must remain")
        config = self.write(self.target, "configuration.lua", "device config")
        self.deploy(expected_success=False)
        self.assertTrue(stale.exists())
        self.assertEqual(config.read_text(), "device config")

    def test_destination_must_be_plugins_directory(self):
        wrong = self.root / "other"
        wrong.mkdir()
        self.deploy(expected_success=False, plugins=wrong)
        self.assertEqual(list(wrong.iterdir()), [])

    def test_payload_cannot_be_inside_the_installed_plugin(self):
        nested_payload = self.target / "payload"
        self.write(nested_payload, "main.lua", "new")
        self.write(nested_payload, "_meta.lua", "meta")
        self.deploy(expected_success=False, payload=nested_payload)
        self.assertTrue((nested_payload / "main.lua").exists())

    def test_managed_symlinks_are_rejected(self):
        outside = self.write(self.root, "outside/important.txt", "keep")
        self.target.mkdir(parents=True)
        link = self.target / "redirect"
        try:
            link.symlink_to(outside.parent, target_is_directory=True)
        except OSError:
            self.skipTest("Creating symlinks is not permitted on this system")
        self.deploy(expected_success=False)
        self.assertEqual(outside.read_text(), "keep")

    @unittest.skipUnless(os.name == "nt" and shutil.which("powershell"), "Windows PowerShell is required")
    def test_adb_transport_staging_and_failure_handling(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ["deploy-android.ps1", "sync-android.sh"]:
            shutil.copyfile(REPOSITORY / "scripts" / name, scripts / name)
        source = self.root / "AI_Dictionary.koplugin"
        shutil.copytree(self.payload, source)
        for relative in ["configuration.lua", "Lookups/Lookups.txt", "Audio/cache.mp3", ".update-old/file"]:
            self.write(source, relative, "must not upload")
        self.write(source, "Resources/Lookups/current.lua", "included")
        fake_adb = self.write(self.root, "fake adb.ps1", r"""
$record = @{ Arguments = @($args) }
if ($args -contains 'push') {
    $stage = $args[[array]::IndexOf($args, 'push') + 1]
    $record.Stage = $stage
    $record.Files = @(Get-ChildItem -LiteralPath $stage -Recurse -File | ForEach-Object {
        $_.FullName.Substring($stage.Length + 1).Replace('\', '/')
    })
}
$record | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:AIDICT_TEST_LOG
$global:LASTEXITCODE = 0
if (($env:AIDICT_TEST_FAILURE -eq 'push' -and $args -contains 'push') -or
    ($env:AIDICT_TEST_FAILURE -eq 'apply' -and $args -contains 'shell' -and $args[-1].StartsWith('sh '))) {
    $global:LASTEXITCODE = 1
}
if ($args -contains 'get-state') { Write-Output 'device' }
if ($args -contains 'resolve-activity') {
    if ($env:AIDICT_TEST_FAILURE -eq 'resolve') {
        Write-Output 'No activity found'
    } else {
        Write-Output 'priority=0 preferredOrder=0 match=0x108000'
        Write-Output 'org.koreader.launcher/.MainActivity'
    }
}
if ($args -contains 'am' -and $args -contains 'start') {
    if ($env:AIDICT_TEST_FAILURE -eq 'launch') {
        $global:LASTEXITCODE = 1
    } elseif ($env:AIDICT_TEST_FAILURE -eq 'launch-output') {
        # Some Android shell commands report an error despite returning zero.
        Write-Output 'Error: Activity could not be started'
    } else {
        Write-Output 'Starting: Intent { cmp=org.koreader.launcher/.MainActivity }'
        Write-Output 'Status: ok'
        Write-Output 'Complete'
    }
}
""")
        log = self.root / "adb.jsonl"
        cases = [("", False), ("", True), ("push", False), ("apply", False),
                 ("resolve", False), ("launch", False), ("launch-output", False)]
        for failure, skip_launch in cases:
            with self.subTest(failure=failure or "success", skip_launch=skip_launch):
                log.write_text("")
                extra_arguments = ["-SkipLaunch"] if skip_launch else []
                result = subprocess.run(
                    ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                     str(scripts / "deploy-android.ps1"), "-AdbPath", str(fake_adb),
                     "-Serial", "GO7-TEST"] + extra_arguments,
                    capture_output=True, text=True,
                    env={**os.environ, "AIDICT_TEST_LOG": str(log), "AIDICT_TEST_FAILURE": failure},
                )
                self.assertEqual(result.returncode, 1 if failure else 0, result.stdout + result.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                for call in calls:
                    self.assertEqual(call["Arguments"][:2], ["-s", "GO7-TEST"])
                push = next(call for call in calls if "push" in call["Arguments"])
                self.assertEqual(set(push["Files"]), {
                    "AI_Dictionary.koplugin/main.lua", "AI_Dictionary.koplugin/_meta.lua",
                    "AI_Dictionary.koplugin/Resources/Lookups/current.lua", "sync-android.sh",
                })
                self.assertFalse(Path(push["Stage"]).exists())
                applies = [call for call in calls if call["Arguments"][-1].startswith("sh ")]
                self.assertEqual(len(applies), 0 if failure == "push" else 1)
                resolves = [call for call in calls if "resolve-activity" in call["Arguments"]]
                launches = [call for call in calls if "am" in call["Arguments"]]
                should_resolve = failure not in ("push", "apply") and not skip_launch
                should_launch = should_resolve and failure != "resolve"
                self.assertEqual(len(resolves), int(should_resolve))
                self.assertEqual(len(launches), int(should_launch))
                if resolves:
                    self.assertLess(calls.index(applies[0]), calls.index(resolves[0]))
                if launches:
                    arguments = launches[0]["Arguments"]
                    self.assertIn("-S", arguments)
                    self.assertIn("-W", arguments)
                    self.assertEqual(arguments[arguments.index("-n") + 1], "org.koreader.launcher/.MainActivity")
                    self.assertLess(calls.index(resolves[0]), calls.index(launches[0]))
                if failure in ("resolve", "launch", "launch-output"):
                    self.assertIn("Plugin files were deployed, but opening KOReader failed", " ".join(result.stderr.split()))
                self.assertRegex(calls[-1]["Arguments"][-1],
                                 r"^rm -rf '/data/local/tmp/ai-dictionary-deploy-[a-f0-9]{32}'$")
                self.assertEqual("Deployment complete." in result.stdout, not failure)


if __name__ == "__main__":
    unittest.main(verbosity=2)
