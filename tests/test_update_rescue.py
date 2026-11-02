"""Run with: python3 -m unittest discover -s tests -v

Uses disposable, non-bootable UKIs and test signing keys. Real ukify, bootctl,
and sbctl inspect/sign/verify the fixtures; mount discovery, capacity, the
expensive builder, and selected I/O failures are simulated. All writes stay
inside temporary directories. No real ESP, keys, or package manager is used.
"""

import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid


REPO = Path(__file__).resolve().parents[1]
UPDATER = REPO / "settings/maintenance/usr/local/sbin/update-rescue"
UKIFY = Path("/usr/lib/systemd/ukify")


def command(args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, timeout=30, **kwargs)
    if result.returncode:
        raise AssertionError((args, result.returncode, result.stdout, result.stderr))
    return result


def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


class UpdateRescueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for name in ("openssl", "sbctl", "bootctl", "jq", "flock"):
            if not shutil.which(name):
                raise unittest.SkipTest(f"Requires {name}")
        if not UKIFY.exists():
            raise unittest.SkipTest("Requires systemd-ukify and python-pefile")
        cls.prefix = []
        if os.geteuid() != 0:
            if not shutil.which("unshare"):
                raise unittest.SkipTest("Requires root or unprivileged user namespaces")
            cls.prefix = ["unshare", "--user", "--map-root-user", "--"]
            probe = subprocess.run(cls.prefix + ["true"], capture_output=True)
            if probe.returncode:
                raise unittest.SkipTest("Unprivileged user namespaces are unavailable")
        cls.temp = tempfile.TemporaryDirectory(prefix="test-update-rescue-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.fixtures = Path(cls.temp.name)
        keys = cls.fixtures / "keys"
        for role in ("db", "PK", "KEK"):
            (keys / role).mkdir(parents=True)
        command(["openssl", "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes",
                 "-sha256", "-days", "1", "-subj", "/CN=Disposable updater test/",
                 "-keyout", str(keys / "db/db.key"), "-out", str(keys / "db/db.pem")])
        for role in ("PK", "KEK"):
            for suffix in ("key", "pem"):
                shutil.copyfile(keys / f"db/db.{suffix}", keys / role / f"{role}.{suffix}")
        (cls.fixtures / "GUID").write_text(str(uuid.uuid4()))
        (cls.fixtures / "linux").write_bytes(b"Not a bootable kernel: signing fixture\n")
        (cls.fixtures / "initrd").write_bytes(b"Not a bootable initrd\n")
        for version, image_id in (("old", "arch-rescue"), ("new", "arch-rescue"), ("wrong", "other")):
            osrel = cls.fixtures / f"{version}.os-release"
            osrel.write_text(f'ID=arch\nPRETTY_NAME="Arch Rescue"\nIMAGE_ID={image_id}\nIMAGE_VERSION={version}\n')
            command([str(UKIFY), "build", "--linux", str(cls.fixtures / "linux"),
                     "--initrd", str(cls.fixtures / "initrd"), "--os-release", "@" + str(osrel),
                     "--uname", f"test-kernel-{version}", "--output", str(cls.fixtures / f"{version}.efi")])

    def setUp(self):
        self.temp_case = tempfile.TemporaryDirectory(prefix="case-", dir=self.fixtures)
        self.addCleanup(self.temp_case.cleanup)
        self.root = Path(self.temp_case.name)
        self.esp = self.root / "efi"
        self.state = self.root / "sbctl"
        self.repo = self.root / "checkout with spaces"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.esp / "EFI/Linux").mkdir(parents=True)
        self.target = self.esp / "EFI/Linux/arch-rescue.efi"
        self.backup = self.state / "rescue-backups/arch-rescue.efi"
        shutil.copytree(self.fixtures / "keys", self.state / "keys")
        self.config = self.root / "sbctl.yml"
        self.database = self.root / "files.json"
        self.database.write_text("{}")
        self.config.write_text(f"keydir: {self.state}/keys\nguid: {self.fixtures}/GUID\n"
                               f"files_db: {self.database}\nlandlock: true\n")
        self.env = os.environ | {"SYSTEMD_ESP_PATH": str(self.esp)}
        shutil.copyfile(self.fixtures / "old.efi", self.target)
        command(["sbctl", "--config", str(self.config), "sign", str(self.target)], env=self.env)
        self.old = self.target.read_bytes()
        self.backup.parent.mkdir()
        self.backup.write_bytes(b"pre-existing backup sentinel")
        self.log = self.root / "operations"
        self.log.touch()
        self.env |= {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "TEST_ESP": str(self.esp), "TEST_STATE": str(self.state),
            "TEST_TARGET": str(self.target), "TEST_BACKUP": str(self.backup),
            "TEST_CONFIG": str(self.config), "TEST_LOG": str(self.log),
            "TEST_BUILD": str(self.root / "build-ran"),
            "TEST_IMAGE": str(self.fixtures / "new.efi"), "FAIL_MODE": "",
        }
        (self.repo / "rescue-uki").mkdir(parents=True)
        (self.repo / "build-common.bash").touch()
        executable(self.repo / "rescue-uki/build.sh", '''#!/bin/bash
set -euo pipefail
touch "$TEST_BUILD"
[[ "$FAIL_MODE" != build ]] || exit 71
root=$(dirname "$(dirname "$0")")
mkdir -p "$root/artifacts"
cp "$TEST_IMAGE" "$root/artifacts/arch-rescue.efi"
''')
        executable(self.bin / "findmnt", '''#!/bin/bash
path=${@: -1}
if [[ "$path" == / ]]; then
    [[ "$FAIL_MODE" != live ]] && echo btrfs || echo tmpfs
elif [[ "$path" == "$TEST_ESP" ]]; then
    [[ "$FAIL_MODE" != no-esp ]] || exit 1
    echo vfat
elif [[ "$path" == "$TEST_STATE" ]]; then
    [[ "$FAIL_MODE" != no-state ]] || exit 1
    echo btrfs
else exit 1
fi
''')
        executable(self.bin / "df", '''#!/bin/bash
if [[ "$FAIL_MODE" == full ]]; then
    printf 'Filesystem 1-blocks Used Available Use%% Mounted on\ntest 100 99 1 99%% %s\n' "$TEST_ESP"
else exec /usr/bin/df "$@"
fi
''')
        executable(self.bin / "sbctl", '''#!/bin/bash
printf 'sbctl %s\n' "$*" >>"$TEST_LOG"
if [[ "$1" == sign && "$FAIL_MODE" == sign ]]; then exit 72; fi
if [[ "$1" == --json && "$2" == verify && "$FAIL_MODE" == unsigned ]]; then
    exec /usr/bin/jq -n --arg file "$3" '[{file_name:$file,is_signed:0}]'
fi
exec /usr/bin/sbctl --config "$TEST_CONFIG" "$@"
''')
        executable(self.bin / "cp", '''#!/bin/bash
if [[ "$FAIL_MODE" == backup && "${@: -1}" == "$TEST_STATE"/rescue-backups/.arch-rescue-backup.* ]]; then
    exit 73
fi
exec /usr/bin/cp "$@"
''')
        executable(self.bin / "mv", '''#!/bin/bash
if [[ "${@: -1}" == "$TEST_TARGET" ]]; then
    [[ "$FAIL_MODE" != promote ]] || exit 74
    printf 'promote\n' >>"$TEST_LOG"
fi
exec /usr/bin/mv "$@"
''')
        executable(self.bin / "sync", '''#!/bin/bash
if [[ "$FAIL_MODE" == final-sync && "${@: -1}" == "$TEST_ESP" ]]; then exit 75; fi
exec /usr/bin/sync "$@"
''')
        # Redirect only the three fixed deployment locations. The CLI logic,
        # real signature operations, and actual file promotion are unchanged.
        text = UPDATER.read_text()
        text = text.replace("ESP=/efi\n", f"ESP={self.esp}\n")
        text = text.replace("SBCTL_STATE=/var/lib/sbctl\n", f"SBCTL_STATE={self.state}\n")
        self.lock = self.root / "update.lock"
        text = text.replace("LOCK_FILE=/run/lock/update-rescue.lock\n", f"LOCK_FILE={self.lock}\n")
        self.updater = self.root / "update-rescue"
        executable(self.updater, text)

    def update(self, *args, mode="", image=None):
        env = self.env | {"FAIL_MODE": mode}
        if image:
            env["TEST_IMAGE"] = str(image)
        if not args:
            args = (str(self.repo),)
        return subprocess.run(self.prefix + ["bash", str(self.updater), *args], env=env,
                              text=True, capture_output=True, timeout=30)

    def assert_no_staging(self):
        self.assertEqual(list(self.esp.glob("EFI/Linux/.arch-rescue-update.*")), [])
        self.assertEqual(list(self.backup.parent.glob(".arch-rescue-backup.*")), [])

    def test_update_signs_before_promotion_and_preserves_exact_previous_image(self):
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.backup.read_bytes(), self.old)
        self.assertNotEqual(self.target.read_bytes(), self.old)
        inspection = json.loads(command([str(UKIFY), "--json=short", "inspect", str(self.target)]).stdout)
        self.assertIn("IMAGE_VERSION=new", inspection[".osrel"]["text"])
        verification = json.loads(command(["/usr/bin/sbctl", "--config", str(self.config),
                                           "--json", "verify", str(self.target)], env=self.env).stdout)
        self.assertEqual(verification[0]["is_signed"], 1)
        operations = self.log.read_text().splitlines()
        promote = operations.index("promote")
        self.assertTrue(any("--json verify" in line and ".arch-rescue-update." in line
                            for line in operations[:promote]))
        self.assertIn("IMAGE_VERSION=new", result.stdout)
        self.assertEqual(self.database.read_text(), "{}")
        self.assert_no_staging()

    def test_restore_is_offline_and_preserves_backup(self):
        self.backup.write_bytes(self.old)
        self.target.write_bytes(b"rejected image")
        result = self.update("--restore")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.target.read_bytes(), self.old)
        self.assertEqual(self.backup.read_bytes(), self.old)
        self.assertFalse((self.root / "build-ran").exists())
        self.assertNotIn("sbctl sign", self.log.read_text())
        self.assertIn("restored and verified", result.stdout)
        self.assert_no_staging()

    def test_preflight_failures_do_not_start_build(self):
        for mode in ("no-esp", "no-state", "live"):
            with self.subTest(mode=mode):
                result = self.update(mode=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "build-ran").exists())
                self.assertEqual(self.target.read_bytes(), self.old)

    def test_failures_before_backup_leave_target_and_existing_backup_untouched(self):
        for mode in ("build", "full", "sign", "unsigned", "backup"):
            with self.subTest(mode=mode):
                result = self.update(mode=mode)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.target.read_bytes(), self.old)
                self.assertEqual(self.backup.read_bytes(), b"pre-existing backup sentinel")
                self.assert_no_staging()

    def test_wrong_image_identity_is_not_signed_or_installed(self):
        result = self.update(image=self.fixtures / "wrong.efi")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("sbctl sign", self.log.read_text())
        self.assertEqual(self.target.read_bytes(), self.old)
        self.assert_no_staging()

    def test_failed_promotion_preserves_current_image_and_completed_backup(self):
        result = self.update(mode="promote")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.target.read_bytes(), self.old)
        self.assertEqual(self.backup.read_bytes(), self.old)
        self.assert_no_staging()

    def test_error_after_promotion_reports_available_restore(self):
        result = self.update(mode="final-sync")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(self.target.read_bytes(), self.old)
        self.assertEqual(self.backup.read_bytes(), self.old)
        self.assertIn("was replaced", result.stderr)
        self.assertIn("update-rescue --restore", result.stderr)
        self.assert_no_staging()

    def test_unsigned_backup_is_rejected_even_when_sbctl_exits_zero(self):
        shutil.copyfile(self.fixtures / "old.efi", self.backup)
        result = self.update("--restore")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.target.read_bytes(), self.old)
        self.assert_no_staging()

    def test_missing_backup_is_rejected(self):
        self.backup.unlink()
        result = self.update("--restore")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.target.read_bytes(), self.old)

    def test_concurrent_update_is_rejected(self):
        with self.lock.open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already running", result.stderr)
        self.assertFalse((self.root / "build-ran").exists())


if __name__ == "__main__":
    unittest.main()
