"""Keep nested package builds parallel when sharing a dependency graph."""
import pathlib
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[4]


class ExternalMakeTests(unittest.TestCase):
    def run_logged_graph(self, build_log=True, verbose=False, fail=False):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            shutil.copy(ROOT / '.github/act/external-kmods.mk', root / 'external.mk')
            (root / 'Makefile').write_text(
                'TOPDIR:=$(CURDIR)\nSHELL:=/bin/bash\n'
                f'SCRIPT_DIR:={ROOT / "scripts"}\n'
                'BUILD_LOG_DIR:=$(CURDIR)/logs\n'
                f'include {ROOT / "include/verbose.mk"}\n'
                f'include {ROOT / "include/subdir.mk"}\n'
                '.PHONY: first second shared\n'
                'shared:\n\t@echo built >> shared.log\n'
                'define package_target\n'
                '$(1): shared\n'
                '\t$(call log_make,child-$(1),compile,host)\n'
                'endef\n'
                '$(eval $(call package_target,first))\n'
                '$(eval $(call package_target,second))\n')
            for name in ('first', 'second'):
                child = root / ('child-' + name)
                child.mkdir()
                (child / 'Makefile').write_text(
                    'override MAKEFLAGS=\n'
                    'host-compile:\n'
                    '\t@test -n "$(MAKE_JOBSERVER)"\n'
                    '\t@echo "$(MAKE_JOBSERVER)" >> ../jobserver.log\n'
                    '\t@echo CHILD_STDOUT\n\t@echo CHILD_STDERR >&2\n'
                    '\t@if [ "$(FAIL)" = 1 ]; then echo CHILD_FAILURE >&2; exit 7; fi\n')
            env = os.environ.copy()
            for name in ('QUIET', 'OPENWRT_VERBOSE', 'NO_TRACE_MAKE', 'SUBMAKE',
                         'OPENWRT_BUILD', 'MAKE_JOBSERVER'):
                env.pop(name, None)
            command = ['make', '-r', '-f', 'external.mk', '-j4', 'first', 'second']
            if build_log:
                command.append('BUILD_LOG=1')
            if verbose:
                command.append('V=s')
            if fail:
                command.append('FAIL=1')
            result = subprocess.run(command, cwd=root, env=env, text=True,
                                    capture_output=True, timeout=30)
            output = result.stdout + result.stderr
            self.assertNotIn('syntax error', output)
            self.assertEqual(result.returncode == 0, not fail, output)
            self.assertEqual((root / 'shared.log').read_text().splitlines(), ['built'])
            self.assertEqual(len((root / 'jobserver.log').read_text().splitlines()), 2)
            if build_log:
                for name in ('first', 'second'):
                    log = (root / 'logs' / ('child-' + name) / 'host-compile.txt').read_text()
                    self.assertIn('CHILD_STDOUT', log)
                    self.assertIn('CHILD_STDERR', log)
                    self.assertIn('time: child-' + name + '/host-compile#', log)
                    if fail:
                        self.assertIn('CHILD_FAILURE', log)

    def test_default_quiet_logging_uses_executable_submake(self):
        self.run_logged_graph()

    def test_verbose_logging_uses_executable_submake(self):
        self.run_logged_graph(verbose=True)

    def test_default_quiet_without_build_log(self):
        self.run_logged_graph(build_log=False)

    def test_failure_survives_time_and_tee(self):
        self.run_logged_graph(fail=True)

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
