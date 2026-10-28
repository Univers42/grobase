"""Exercise ephemeral credentials and peer certificate trust without deployed services."""
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


class DrillTlsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        helper = Path(__file__).resolve().parents[1] / "verify/recovery-drill-tls.sh"
        for name in ("first", "second"):
            directory = self.root / name
            directory.mkdir(mode=0o700)
            subprocess.run(["bash", "-euc", 'umask 077; source "$1"; create_drill_tls "$2"',
                            "drill", str(helper), str(directory)], check=True)

    def test_credentials_are_unique_and_private(self):
        for filename in ("pg.env", "store.env"):
            first = self.root / "first" / filename
            second = self.root / "second" / filename
            self.assertNotEqual(first.read_text(), second.read_text())
            self.assertEqual(stat.S_IMODE(first.stat().st_mode), 0o600)
            for value in first.read_text().splitlines():
                self.assertGreaterEqual(len(value.split("=", 1)[1]), 24)

    def test_ca_and_hostname_verification(self):
        directory = self.root / "first"
        for peer in ("pg", "store"):
            certificate = directory / peer / "public.crt"
            command = ["openssl", "verify", "-CAfile", str(directory / "ca.crt"),
                       "-verify_hostname", peer, str(certificate)]
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
            wrong_host = command.copy()
            wrong_host[-2] = "wrong-host"
            self.assertNotEqual(subprocess.run(wrong_host, capture_output=True).returncode, 0)
            wrong_ca = command.copy()
            wrong_ca[3] = str(self.root / "second" / "ca.crt")
            self.assertNotEqual(subprocess.run(wrong_ca, capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
