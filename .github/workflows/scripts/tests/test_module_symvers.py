"""Exercise OpenWrt's actual symbol collector with old/new Kbuild output."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[4]


class ModuleSymversTests(unittest.TestCase):
    def collect(self, entries, version='7.2', symlink=False):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            package = root / 'package'
            package.mkdir()
            build = root / 'alias' if symlink else package
            if symlink:
                build.symlink_to(package, target_is_directory=True)
            for name, symbols, order in entries:
                target = package / name
                target.mkdir(exist_ok=True)
                (target / 'Module.symvers').write_text(symbols.replace('@ABS@', str(package)))
                (target / 'modules.order').write_text(order)
            (package / 'Module.symvers.tmp').write_text('stale export must disappear\n')
            source = (ROOT / 'include/kernel.mk').read_text()
            macro = 'define collect_module_symvers\n' + source.split('define collect_module_symvers\n', 1)[1].split('\nendef', 1)[0] + '\nendef\n'
            (root / 'Makefile').write_text(
                f'PKG_BUILD_DIR:={build}\nPKG_SYMVERS_DIR:={root}/symbols\n'
                f'KERNEL_PATCHVER:={version}\n'
                'PKG_EXTMOD_SUBDIRS:=' + ' '.join(name for name, _, _ in entries) + '\n' + macro +
                'define invocation\nall:\n\t$(call collect_module_symvers)\nendef\n'
                'PKG_NAME:=test\n$(eval $(invocation))\n')
            result = subprocess.run(['make', '-r', '-s'], cwd=root, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            return (root / 'symbols/test.symvers').read_text()

    def test_absolute_and_symlink_build_paths(self):
        for symlink in (False, True):
            with self.subTest(symlink=symlink):
                result = self.collect([('.', '0x1 own @ABS@/driver EXPORT_SYMBOL\n', 'driver.o\n')], symlink=symlink)
                self.assertIn(' own ', result)

    def test_relative_module_paths_on_all_supported_kernels(self):
        for version in ('6.12', '6.18', '7.2'):
            for suffix in ('.o', '.ko'):
                with self.subTest(version=version, suffix=suffix):
                    result = self.collect([('.', '0x1 own drivers/unit EXPORT_SYMBOL\n'
                                           '0x2 foreign other/module EXPORT_SYMBOL\n',
                                            'drivers/unit' + suffix + '\n')], version=version)
                    self.assertIn(' own ', result)
                    self.assertNotIn('foreign', result)

    def test_each_subdirectory_is_collected_and_stale_symbols_removed(self):
        result = self.collect([
            ('first', '0x1 absolute @ABS@/first/driver EXPORT_SYMBOL\n', 'driver.o\n'),
            ('second', '0x2 relative drivers/unit EXPORT_SYMBOL\n', 'drivers/unit.o\n'),
        ])
        self.assertIn(' absolute ', result)
        self.assertIn(' relative ', result)
        self.assertNotIn('stale', result)

    def test_module_without_exports_succeeds(self):
        self.assertEqual(self.collect([('.', '', 'drivers/unit.o\n')]), '')


if __name__ == '__main__':
    unittest.main()
