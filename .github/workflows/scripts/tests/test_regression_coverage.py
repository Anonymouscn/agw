import hashlib
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[4]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / '.github/act' / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.plan = module('regression-plan').plan
        self.tsv = ('key\ttarget\tkernel\ttesting\trelease\n'
                    'x86-64-k7.2\tx86/64\t7.2\t0\t7.2.3\n'
                    'x86-64-k6.18\tx86/64\t6.18\t1\t6.18.44\n'
                    'malta-be-k6.12\tmalta/be\t6.12\t0\t6.12.107\n')

    def test_all_versions_testing_mode_and_filters(self):
        self.assertEqual(len(self.plan(self.tsv)), 3)
        self.assertTrue(self.plan(self.tsv, '6.18')[0]['testing'])
        self.assertEqual(len(self.plan(self.tsv, targets='x86/64')), 2)

    def test_invalid_or_empty_selection_fails(self):
        for kwargs in ({'kernel': '9.9'}, {'targets': 'missing/device'}, {'parallel': 0}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                self.plan(self.tsv, **kwargs)

    def test_duplicate_kernel_mode_does_not_duplicate_build(self):
        self.assertEqual(len(self.plan(self.tsv + self.tsv.splitlines()[1] + '\n')), 3)


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.mod = module('package-coverage')
        self.catalog = self.mod.metadata('Source-Makefile: package/test/Makefile\n'
                                         'Package: installed\nType: ipkg\n'
                                         'Package: hidden\nDepends: @LINUX_6_12\n'
                                         'Package: boot-tool\nType: bin\nBuild-Only: 1\n')
        self.config = 'CONFIG_PACKAGE_installed=m\nCONFIG_PACKAGE_boot-tool=y\n'

    def test_missing_package_is_not_a_success(self):
        report = self.mod.audit(self.catalog, self.config, [], 0)
        self.assertFalse(report['package_build_complete'])
        self.assertEqual(report['selected_apk_missing'], ['installed'])

    def test_disabled_dependency_and_failed_build_are_not_passes(self):
        report = self.mod.audit(self.catalog, self.config, [{'name': 'installed'}], 2)
        self.assertFalse(report['package_build_complete'])
        hidden = next(row for row in report['packages'] if row['name'] == 'hidden')
        self.assertTrue(hidden['status'].startswith('NOT_SELECTED'))
        self.assertEqual(hidden['Depends'], '@LINUX_6_12')

    def test_build_only_artifact_policy_and_empty_inventory(self):
        self.assertTrue(self.mod.audit(self.catalog, self.config, [{'name': 'installed'}], 0)['package_build_complete'])
        self.assertFalse(self.mod.audit({}, '', [], 0)['package_build_complete'])
        self.catalog['boot-tool']['Type'] = 'bin ipkg'
        self.catalog['boot-tool'].pop('Build-Only')
        self.assertIn('boot-tool', self.mod.audit(self.catalog, self.config, [{'name': 'installed'}], 0)['selected_apk_missing'])

    def test_duplicate_metadata_fails(self):
        with self.assertRaises(ValueError):
            self.mod.metadata('Source-Makefile: package/a/Makefile\nPackage: a\nPackage: a\n')

    def test_description_text_cannot_create_fake_package_headers(self):
        result = self.mod.metadata('Source-Makefile: package/a/Makefile\nPackage: a\n'
                                   'Description: example\nPackage: not-a-header\n@@\n')
        self.assertEqual(set(result), {'a'})

    def test_abi_renamed_package_requires_matching_origin_and_abi(self):
        catalog = self.mod.metadata('Source-Makefile: package/libs/toolchain/Makefile\n'
                                    'Package: libgcc\nABI-Version: 1\nType: ipkg\n')
        config = 'CONFIG_PACKAGE_libgcc=y\n'
        archive = {'name': 'libgcc1', 'provides': ['libgcc'], 'abi': '1',
                   'origin': 'feeds/base/libs/toolchain'}
        self.assertTrue(self.mod.audit(catalog, config, [archive], 0)['package_build_complete'])
        self.assertTrue(self.mod.audit(catalog, config, [dict(archive, provides=['libgcc=14.4'])], 0)['package_build_complete'])
        self.assertFalse(self.mod.audit(catalog, config, [dict(archive, abi='2')], 0)['package_build_complete'])
        self.assertFalse(self.mod.audit(catalog, config, [dict(archive, origin='feeds/other/toolchain')], 0)['package_build_complete'])

    def test_feed_symlink_origin_uses_real_source_category(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / 'feeds/packages/libs/foo'
            source.mkdir(parents=True)
            (source / 'Makefile').write_text('fixture\n')
            alias = root / 'package/feeds/packages/foo'
            alias.parent.mkdir(parents=True)
            alias.symlink_to(source, target_is_directory=True)
            self.assertEqual(self.mod.expected_origin(root, 'package/feeds/packages/foo/Makefile'),
                             'feeds/packages/libs/foo')

    def test_missing_runtime_provider_and_wrong_version_are_detected(self):
        archives = [{'name': 'frontend', 'version': '1', 'depends': ['backend>=2']},
                    {'name': 'backend', 'version': '1'}]
        compare = lambda left, right: '<' if left < right else '>'
        self.assertFalse(self.mod.dependency_audit(archives, compare)['complete'])
        archives[1]['version'] = '2'
        self.assertTrue(self.mod.dependency_audit(archives, compare)['complete'])
        self.assertFalse(self.mod.dependency_audit(archives[:1], compare)['complete'])

    def test_virtual_provider_without_version_cannot_satisfy_versioned_dependency(self):
        archives = [{'name': 'frontend', 'depends': ['virtual>=2', '!alternative']},
                    {'name': 'implementation', 'provides': ['virtual']}]
        result = self.mod.dependency_audit(archives)
        self.assertFalse(result['complete'])
        self.assertEqual(len(result['unverified_version_constraints']), 1)

    def test_image_manifest_missing_image_and_profile_are_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            target = root / 'bin/targets/x86/64'
            target.mkdir(parents=True)
            image = target / 'image.img'
            image.write_bytes(b'firmware')
            (target / 'profiles.json').write_text(json.dumps({'profiles': {
                'generic': {'images': [{'name': image.name, 'sha256': hashlib.sha256(image.read_bytes()).hexdigest()}]}}}))
            config = 'CONFIG_TARGET_ALL_PROFILES=y\nCONFIG_TARGET_DEVICE_x86_64_DEVICE_generic=y\n'
            self.assertTrue(self.mod.image_audit(root, config)['image_build_complete'])
            self.assertFalse(self.mod.image_audit(root, config + 'CONFIG_TARGET_DEVICE_x86_64_DEVICE_other=y\n')['image_build_complete'])
            image.unlink()
            self.assertFalse(self.mod.image_audit(root, config)['image_build_complete'])


class FeedLockTests(unittest.TestCase):
    def test_dirty_feed_and_untracked_patch_survive_clean_restore(self):
        mod = module('feed-lock')
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            origin = root / 'origin'
            origin.mkdir()
            subprocess.run(['git', 'init', '-q', str(origin)], check=True)
            (origin / 'Makefile').write_text('original\n')
            subprocess.run(['git', '-C', str(origin), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(origin), '-c', 'user.name=Test', '-c',
                            'user.email=test@example.invalid', 'commit', '-qm', 'fixture'], check=True)
            checkout = root / 'checkout'
            (checkout / 'feeds').mkdir(parents=True)
            config = 'src-git packages ' + str(origin) + '\n'
            (checkout / 'feeds.conf.default').write_text(config)
            feed = checkout / 'feeds/packages'
            subprocess.run(['git', 'clone', '-q', str(origin), str(feed)], check=True)
            (feed / 'Makefile').write_text('changed\n')
            (feed / 'fix.patch').write_text('untracked fix\n')
            lock = root / 'feeds.lock.json'
            mod.capture(checkout, lock)
            clean = root / 'clean'
            clean.mkdir()
            (clean / 'feeds.conf.default').write_text(config)
            mod.restore(clean, lock)
            self.assertEqual((clean / 'feeds/packages/Makefile').read_text(), 'changed\n')
            self.assertEqual((clean / 'feeds/packages/fix.patch').read_text(), 'untracked fix\n')
            with self.assertRaises(ValueError):
                mod.restore(clean, lock)
            data = json.loads(lock.read_text())
            data['feeds'][0]['patch'] += 'corrupted'
            lock.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                mod.load(clean, lock)


class SummaryTests(unittest.TestCase):
    def test_missing_combinations_and_never_selected_are_visible(self):
        mod = module('regression-summary')
        plan = {'matrix': [{'key': 'x86-64-k7.2', 'release': '7.2.3'},
                           {'key': 'malta-be-k6.18', 'release': '6.18.44'}]}
        report = {'key': 'x86-64-k7.2', 'compiled_releases': ['7.2.3'], 'run_exit': 0,
                  'package_build_complete': True, 'all_userspace_selected': True, 'all_kmods_selected': True,
                  'packages': [{'name': 'hidden', 'source': 'package/test/Makefile', 'status': 'NOT_SELECTED_REVIEW_DEPENDENCIES_OR_PROVIDER'}]}
        result = mod.aggregate(plan, [report])
        self.assertFalse(result['build_matrix_complete'])
        self.assertEqual(result['missing_or_not_run'], ['malta-be-k6.18'])
        self.assertEqual(len(result['never_selected']), 1)

    def test_wrong_kernel_and_duplicate_reports_cannot_pass(self):
        mod = module('regression-summary')
        plan = {'matrix': [{'key': 'x86-64-k7.2', 'release': '7.2.3'}]}
        report = {'key': 'x86-64-k7.2', 'compiled_releases': ['6.18.44'], 'run_exit': 0,
                  'package_build_complete': True, 'all_userspace_selected': True,
                  'all_kmods_selected': True, 'packages': []}
        self.assertFalse(mod.aggregate(plan, [report])['build_matrix_complete'])
        report['compiled_releases'] = ['7.2.3']
        self.assertTrue(mod.aggregate(plan, [report])['build_matrix_complete'])
        self.assertFalse(mod.aggregate(plan, [report, report])['build_matrix_complete'])

    def test_firmware_or_later_stage_failure_cannot_be_hidden(self):
        mod = module('regression-summary')
        plan = {'scope': 'firmware', 'matrix': [{'key': 'x86-64-k7.2', 'release': '7.2.3'}]}
        report = {'key': 'x86-64-k7.2', 'compiled_releases': ['7.2.3'], 'run_exit': 0,
                  'package_build_complete': True, 'all_userspace_selected': True,
                  'all_kmods_selected': True, 'packages': []}
        self.assertFalse(mod.aggregate(plan, [report])['build_matrix_complete'])
        report['firmware'] = {'image_build_complete': True}
        self.assertTrue(mod.aggregate(plan, [report])['build_matrix_complete'])
        report['run_exit'] = 1
        self.assertFalse(mod.aggregate(plan, [report])['build_matrix_complete'])


class ConfigDiagnosticsTests(unittest.TestCase):
    def test_recursive_diagnostics_with_zero_exit_still_fail(self):
        valid = module('check-config').valid_config
        self.assertFalse(valid(0, 'tmp/.config-package.in:42:error: recursive dependency detected!\n'))
        self.assertFalse(valid(1, ''))
        self.assertTrue(valid(0, 'warning: symbol reassigned\nconfiguration written\n'))


class FeedCoverageSummaryTests(unittest.TestCase):
    def test_missing_feed_or_wrong_snapshot_cannot_pass(self):
        mod = module('regression-summary')
        plan = {'feeds': 'locked', 'feed_lock_sha256': 'expected', 'expected_feeds': ['packages', 'luci'],
                'matrix': [{'key': 'x86-64-k7.2', 'release': '7.2.3'}]}
        report = {'key': 'x86-64-k7.2', 'compiled_releases': ['7.2.3'], 'run_exit': 0,
                  'package_build_complete': True, 'all_userspace_selected': True, 'all_kmods_selected': True,
                  'packages': [], 'feed_lock_sha256': 'expected', 'feeds_in_metadata': ['packages']}
        self.assertFalse(mod.aggregate(plan, [report])['build_matrix_complete'])
        report['feeds_in_metadata'].append('luci')
        self.assertTrue(mod.aggregate(plan, [report])['build_matrix_complete'])
        report['feed_lock_sha256'] = 'different'
        self.assertFalse(mod.aggregate(plan, [report])['build_matrix_complete'])


if __name__ == '__main__':
    unittest.main()
