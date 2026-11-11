"""Real temporary Git repositories using file:// remotes only.

The probe itself never fetches. Fetches in tests prepare fixtures so ancestry
classification can be verified independently of network access.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "bin/omarchy-branch-watch-check"


class RepoWatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="branch-watch-")
        self.addCleanup(self.tmp.cleanup)
        self.box = Path(self.tmp.name)
        self.home = self.box / "home"
        self.home.mkdir()
        self.config = self.box / "branch-watch.json"
        self.state = self.box / "state" / "branch-watch-state.json"
        self.notify_log = self.box / "notifications"
        self.notify = self.box / "notify-send"
        self.notify.write_text(
            '#!/usr/bin/python3\nimport os,sys\n'
            'with open(os.environ["NOTIFY_LOG"], "a") as f: f.write(repr(sys.argv[1:])+"\\n")\n'
        )
        self.notify.chmod(0o755)
        self.env = {
            "HOME": str(self.home), "PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_ALLOW_PROTOCOL": "file",
            "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            "GIT_SSH_COMMAND": "/usr/bin/false", "BRANCH_WATCH_TIMEOUT": "2",
            "XDG_CONFIG_HOME": str(self.box / "config"), "XDG_STATE_HOME": str(self.box / "state"),
            "BRANCH_WATCH_NOTIFY_SEND": str(self.notify), "NOTIFY_LOG": str(self.notify_log),
        }
        self.repos = {}

    def git(self, directory, *args):
        cmd = ["/usr/bin/git"] + (["-C", str(directory)] if directory else []) + list(args)
        return subprocess.run(cmd, env=self.env, capture_output=True, text=True,
                              check=True, timeout=10).stdout.strip()

    def make_repo(self, name, default="main", branches=()):
        remote = self.box / f"{name}.git"
        work = self.box / f"{name}-work"
        clone = self.box / "clones" / name
        self.git(None, "init", "--bare", f"--initial-branch={default}", str(remote))
        self.git(None, "init", f"--initial-branch={default}", str(work))
        self.git(work, "commit", "--allow-empty", "-m", "initial")
        for branch in branches:
            self.git(work, "branch", branch)
        self.git(work, "remote", "add", "upstream", remote.as_uri())
        self.git(work, "push", "upstream", default, *branches)
        self.git(None, "clone", remote.as_uri(), str(clone))
        for branch in branches:
            self.git(clone, "branch", branch, f"origin/{branch}")
        self.repos[name] = (remote, work, clone, default)
        return remote, work, clone

    def write_config(self, repositories, notifications=True):
        self.config.write_text(json.dumps({
            "schemaVersion": 1, "intervalMinutes": 10,
            "notifications": notifications, "repositories": repositories,
        }))

    def probe(self):
        return subprocess.run(
            ["/bin/bash", str(CHECK), "--json", "--config", str(self.config)],
            env=self.env, capture_output=True, text=True, timeout=15,
        )

    def result(self):
        result = self.probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def notified(self):
        return self.notify_log.read_text().splitlines() if self.notify_log.exists() else []

    def advance(self, name, branch):
        remote, work, clone, default = self.repos[name]
        self.git(work, "switch", branch)
        self.git(work, "commit", "--allow-empty", "-m", "remote update")
        self.git(work, "push", "upstream", branch)

    def test_empty_configuration(self):
        self.write_config([])
        data = self.result()
        self.assertEqual(data["state"], "empty")
        self.assertEqual(data["rows"], [])

    def test_auto_detects_main(self):
        _, _, clone = self.make_repo("modern", "main")
        self.write_config([{"id": "modern", "name": "Modern", "path": str(clone),
                            "remote": "origin", "branches": []}])
        row = self.result()["rows"][0]
        self.assertEqual((row["branch"], row["state"]), ("main", "current"))

    def test_auto_detects_master(self):
        _, _, clone = self.make_repo("legacy", "master")
        self.write_config([{"id": "legacy", "name": "Legacy", "path": str(clone),
                            "remote": "origin", "branches": []}])
        row = self.result()["rows"][0]
        self.assertEqual((row["branch"], row["state"]), ("master", "current"))

    def test_non_array_branches_use_default_detection(self):
        _, _, clone = self.make_repo("legacy", "master")
        for invalid in ("master", {"name": "master"}, None):
            self.write_config([{"id": "legacy", "name": "Legacy", "path": str(clone),
                                "remote": "origin", "branches": invalid}])
            row = self.result()["rows"][0]
            self.assertEqual((row["branch"], row["state"]), ("master", "current"))

    def test_arbitrary_branches_and_non_origin_remote(self):
        _, _, clone = self.make_repo("release", "trunk", ("develop", "release/2.x"))
        self.git(clone, "remote", "rename", "origin", "company")
        self.write_config([{
            "id": "release", "name": "Release", "label": "REL", "path": str(clone),
            "remote": "company", "branches": [
                {"name": "develop", "label": "D"},
                {"name": "release/2.x", "label": "R"},
            ],
        }])
        rows = self.result()["rows"]
        self.assertEqual([(r["branch"], r["branchLabel"], r["state"]) for r in rows],
                         [("develop", "D", "current"), ("release/2.x", "R", "current")])

    def test_unknown_remote_object_is_different_not_behind(self):
        _, _, clone = self.make_repo("backend", "main")
        self.write_config([{"name": "Backend", "path": str(clone),
                            "remote": "origin", "branches": ["main"]}])
        self.advance("backend", "main")
        row = self.result()["rows"][0]
        self.assertEqual(row["state"], "different")
        self.assertIn("without fetching", row["message"])

    def test_known_ancestor_is_behind(self):
        _, _, clone = self.make_repo("backend", "main")
        self.write_config([{"name": "Backend", "path": str(clone),
                            "remote": "origin", "branches": ["main"]}])
        self.advance("backend", "main")
        self.git(clone, "fetch", "origin")
        self.assertEqual(self.result()["rows"][0]["state"], "behind")

    def test_local_ahead_and_diverged(self):
        _, _, clone = self.make_repo("backend", "main")
        self.write_config([{"name": "Backend", "path": str(clone),
                            "remote": "origin", "branches": ["main"]}])
        self.git(clone, "commit", "--allow-empty", "-m", "local")
        self.assertEqual(self.result()["rows"][0]["state"], "ahead")
        self.advance("backend", "main")
        self.git(clone, "fetch", "origin")
        self.assertEqual(self.result()["rows"][0]["state"], "diverged")

    def test_missing_local_branch(self):
        _, _, clone = self.make_repo("backend", "main", ("stable",))
        self.git(clone, "branch", "-D", "stable")
        self.write_config([{"name": "Backend", "path": str(clone),
                            "remote": "origin", "branches": ["stable"]}])
        self.assertEqual(self.result()["rows"][0]["state"], "missing")

    def test_linked_worktree_with_spaces_is_supported(self):
        _, _, clone = self.make_repo("backend", "main")
        linked = self.box / "linked worktree"
        self.git(clone, "worktree", "add", "--detach", str(linked))
        self.write_config([{"name": "Backend", "path": str(linked),
                            "remote": "origin", "branches": ["main"]}])
        self.assertEqual(self.result()["rows"][0]["state"], "current")

    def test_invalid_branch_is_rejected_without_broad_remote_query(self):
        _, _, clone = self.make_repo("backend", "main")
        self.write_config([{"name": "Backend", "path": str(clone),
                            "remote": "origin", "branches": ["bad name", "bad..name"]}])
        rows = self.result()["rows"]
        self.assertEqual([row["state"] for row in rows], ["error", "error"])
        self.assertTrue(all(row["message"] == "Invalid Git branch name" for row in rows))

    def test_notifications_are_deduplicated_across_instances(self):
        _, _, clone = self.make_repo("backend", "main")
        self.write_config([{"name": "Backend", "path": str(clone),
                            "remote": "origin", "branches": ["main"]}])
        self.advance("backend", "main")
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.probe(), range(2)))
        self.assertTrue(all(result.returncode == 0 for result in results))
        self.assertEqual(len(self.notified()), 1)

    def test_same_remote_commit_is_not_notified_again_after_local_recovery(self):
        _, _, clone = self.make_repo("backend", "main")
        self.write_config([{"name": "Backend", "path": str(clone),
                            "remote": "origin", "branches": ["main"]}])
        old = self.git(clone, "rev-parse", "main")
        self.advance("backend", "main")
        self.result()
        self.assertEqual(len(self.notified()), 1)
        self.git(clone, "fetch", "origin")
        current = self.git(clone, "rev-parse", "origin/main")
        self.git(clone, "reset", "--hard", current)
        self.result()
        self.git(clone, "reset", "--hard", old)
        self.result()
        self.assertEqual(len(self.notified()), 1)

    def test_notifications_can_be_disabled(self):
        _, _, clone = self.make_repo("backend", "main")
        self.write_config([{"name": "Backend", "path": str(clone),
                            "remote": "origin", "branches": ["main"]}], notifications=False)
        self.advance("backend", "main")
        self.result()
        self.assertEqual(self.notified(), [])

    def test_repository_notifications_can_be_disabled(self):
        _, _, clone = self.make_repo("backend", "main")
        self.write_config([{"name": "Backend", "path": str(clone), "remote": "origin",
                            "notifications": False, "branches": ["main"]}])
        self.advance("backend", "main")
        self.result()
        self.assertEqual(self.notified(), [])

    def test_probe_does_not_change_repository(self):
        _, _, clone = self.make_repo("backend", "main")
        self.write_config([{"name": "Backend", "path": str(clone),
                            "remote": "origin", "branches": ["main"]}])
        self.advance("backend", "main")
        before = (self.git(clone, "show-ref"), self.git(clone, "count-objects", "-v"))
        self.result()
        self.assertEqual(before, (self.git(clone, "show-ref"), self.git(clone, "count-objects", "-v")))
        self.assertFalse((clone / ".git" / "FETCH_HEAD").exists())

    def test_invalid_and_oversized_configuration_fail(self):
        self.config.write_text("not json")
        self.assertNotEqual(self.probe().returncode, 0)
        self.config.write_bytes(b" " * (1024 * 1024 + 1))
        self.assertNotEqual(self.probe().returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
