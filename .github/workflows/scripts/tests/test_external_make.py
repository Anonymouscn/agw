"""Keep nested package builds parallel when sharing a dependency graph."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[4]


class ExternalMakeTests(unittest.TestCase):
    def test_shared_dependency_and_jobserver_survive_package_flag_reset(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            shutil.copy(ROOT / '.github/act/external-kmods.mk', root / 'external.mk')
            (root / 'Makefile').write_text(
                'ifneq ($(OPENWRT_BUILD),1)\n$(error Internal build required)\nendif\n'
                '.PHONY: first second shared\n'
                'first second: shared\n\t+$(MAKE) -C child verify\n'
                'shared:\n\t@echo built >> shared.log\n')
            (root / 'child').mkdir()
            (root / 'child/Makefile').write_text(
                '# OpenWrt packages clear MAKEFLAGS and use MAKE_JOBSERVER.\n'
                'override MAKEFLAGS=\n'
                'verify:\n\t@test -n "$(MAKE_JOBSERVER)"\n'
                '\t@echo "$(MAKE_JOBSERVER)" >> ../jobserver.log\n')
            result = subprocess.run(['make', '-r', '-f', 'external.mk', '-j4', 'first', 'second'],
                                    cwd=root, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual((root / 'shared.log').read_text().splitlines(), ['built'])
            flags = (root / 'jobserver.log').read_text().splitlines()
            self.assertEqual(len(flags), 2)
            self.assertTrue(all('--jobserver' in flag for flag in flags))


if __name__ == '__main__':
    unittest.main()
