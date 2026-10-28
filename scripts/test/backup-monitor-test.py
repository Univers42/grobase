"""Run the real backup scripts against deterministic command adapters, not live databases."""
import hashlib
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "infra/docker/services/pg-backup/scripts"


class BackupMonitorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        binary = self.work / "bin"
        binary.mkdir()
        store = self.work / "store"
        store.mkdir()
        self.env = {"PATH": str(binary) + ":" + os.environ["PATH"], "HOME": str(self.work),
                    "STORE": str(store), "LOG": str(self.work / "commands"),
                    "DATABASE_URL": "postgres://fixture/source", "PG_BACKUP_BUCKET": "backups",
                    "PG_BACKUP_PREFIX": "postgres", "PG_BACKUP_MONITOR": "1"}
        self.command(binary, "pg_dump", 'test "${FAIL_DUMP:-0}" != 1 || exit 1\nfor arg in "$@"; do case "$arg" in --file=*) printf "database fixture" >"${arg#--file=}";; esac; done')
        self.command(binary, "pg_restore", 'printf "restore\\n" >>"$LOG"\ntest "${FAIL_RESTORE:-0}" != 1')
        self.command(binary, "pg_isready", 'exit 0')
        self.command(binary, "mc", '''printf '%s\\n' "$*" >>"$LOG"
case "$1" in
cp)
  test "${FAIL_UPLOAD:-0}" != 1 || exit 1
  source="$2"; target="$3"
  case "$source" in baas/*) source="$STORE/${source#baas/}";; esac
  case "$target" in baas/*) target="$STORE/${target#baas/}";; esac
  mkdir -p "$(dirname "$target")"
  cp "$source" "$target"
  if [ "${CORRUPT:-0}" = 1 ] && [[ "$2" == baas/* ]]; then printf corrupt >>"$target"; fi
  ;;
cat) cat "$STORE/${2#baas/}";;
rm) test "${FAIL_RETENTION:-0}" != 1;;
esac''')

    def command(self, binary, name, body):
        path = binary / name
        path.write_text("#!/bin/bash\nset -euo pipefail\n" + body + "\n")
        path.chmod(0o755)

    def run_script(self, script, *args):
        return subprocess.run(["bash", str(script), *args], env=self.env, capture_output=True)

    def marker(self):
        return Path(self.env["STORE"]) / "backups/postgres/monitor/last-success"

    def test_success_requires_verified_upload_and_has_checksum(self):
        result = self.run_script(SCRIPTS / "run-backup.sh")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertTrue(self.marker().exists())
        files = list((Path(self.env["STORE"]) / "backups/postgres/logical").glob("*.dump"))
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].with_suffix(".dump.sha256").read_text().split()[0], hashlib.sha256(files[0].read_bytes()).hexdigest())

    def test_dump_failure_does_not_publish_success_or_prune(self):
        self.env["FAIL_DUMP"] = "1"
        self.assertNotEqual(self.run_script(SCRIPTS / "run-backup.sh").returncode, 0)
        self.assertFalse(self.marker().exists())
        self.assertFalse(Path(self.env["LOG"]).exists())

    def test_upload_failure_does_not_publish_success_or_prune(self):
        self.env["FAIL_UPLOAD"] = "1"
        self.assertNotEqual(self.run_script(SCRIPTS / "run-backup.sh").returncode, 0)
        self.assertFalse(self.marker().exists())
        self.assertNotIn("rm --recursive", Path(self.env["LOG"]).read_text())

    def test_corrupted_upload_does_not_publish_success_or_prune(self):
        self.env["CORRUPT"] = "1"
        self.assertNotEqual(self.run_script(SCRIPTS / "run-backup.sh").returncode, 0)
        self.assertFalse(self.marker().exists())
        self.assertNotIn("rm --recursive", Path(self.env["LOG"]).read_text())

    def test_retention_failure_does_not_publish_success(self):
        self.env["FAIL_RETENTION"] = "1"
        self.assertNotEqual(self.run_script(SCRIPTS / "run-backup.sh").returncode, 0)
        self.assertFalse(self.marker().exists())

    def test_monitored_restore_rejects_foreign_and_traversal_keys(self):
        self.env["RESTORE_DATABASE_URL"] = "postgres://fixture/isolated"
        self.env["RESTORE_CONFIRM"] = "RESTORE"
        for key in ("baas/foreign/prefix/logical/test.dump", "logical/../../test.dump"):
            self.assertNotEqual(self.run_script(SCRIPTS / "restore.sh", key).returncode, 0)
        self.assertFalse(Path(self.env["LOG"]).exists())

    def test_checksum_verification_rejects_corruption_and_missing_sidecar(self):
        file = self.work / "fixture.dump"
        file.write_bytes(b"original")
        sidecar = Path(self.env["STORE"]) / "backups/postgres/logical/fixture.dump.sha256"
        sidecar.parent.mkdir(parents=True)
        command = f'. "{SCRIPTS}/monitor.sh"; verify_download "$1" baas/backups/postgres/logical/fixture.dump'
        def verify():
            return subprocess.run(["bash", "-c", command, "_", str(file)], env=self.env, capture_output=True).returncode
        self.assertNotEqual(verify(), 0)
        sidecar.write_text(hashlib.sha256(file.read_bytes()).hexdigest() + "  fixture.dump\n")
        self.assertEqual(verify(), 0)
        file.write_bytes(b"corrupted")
        self.assertNotEqual(verify(), 0)

    def test_freshness_rejects_missing_stale_future_and_invalid_markers(self):
        for value in (None, str(int(time.time()) - 172801), str(int(time.time()) + 1000), "garbage"):
            self.marker().parent.mkdir(parents=True, exist_ok=True)
            if value is not None:
                self.marker().write_text(value)
            result = self.run_script(SCRIPTS / "entrypoint.sh", "liveness")
            self.assertNotEqual(result.returncode, 0, value)

    def test_fresh_verified_marker_is_healthy(self):
        self.marker().parent.mkdir(parents=True)
        self.marker().write_text(str(int(time.time())))
        self.assertEqual(self.run_script(SCRIPTS / "entrypoint.sh", "liveness").returncode, 0)

    def test_monitor_off_preserves_liveness_without_backup_history(self):
        self.env["PG_BACKUP_MONITOR"] = "0"
        self.assertEqual(self.run_script(SCRIPTS / "entrypoint.sh", "liveness").returncode, 0)

    def test_monitored_restore_requires_confirmation_and_distinct_target(self):
        self.env["RESTORE_DATABASE_URL"] = self.env["DATABASE_URL"]
        self.assertNotEqual(self.run_script(SCRIPTS / "restore.sh", "test.dump").returncode, 0)
        self.env["RESTORE_CONFIRM"] = "RESTORE"
        self.assertNotEqual(self.run_script(SCRIPTS / "restore.sh", "test.dump").returncode, 0)
        self.assertFalse(Path(self.env["LOG"]).exists())


if __name__ == "__main__":
    unittest.main()
