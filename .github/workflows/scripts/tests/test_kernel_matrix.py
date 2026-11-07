"""Exercise the actual workflow shell with a small target inventory."""
import json
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[4]


def workflow_script(name):
    lines = (ROOT / '.github/workflows/ci-kernel.yml').read_text().splitlines()
    start = lines.index('      - name: ' + name)
    start += next(i for i, line in enumerate(lines[start:]) if line == '        run: |') + 1
    result = []
    for line in lines[start:]:
        if line.strip() and not line.startswith('          '):
            break
        result.append(line[10:])
    return '\n'.join(result)


class KernelMatrixTests(unittest.TestCase):
    def matrix(self, event, changed):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            perl = root / 'perl'
            perl.write_text('#!/bin/sh\ncase "$2" in\n'
                            'targets) printf "x86/64 x86\\nmalta/be mips\\n" ;;\n'
                            'kernels) printf "x86/64 7.2 6.18\\nmalta/be 6.18 6.18\\n" ;;\nesac\n')
            perl.chmod(0o755)
            output = root / 'output'
            env = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'], GITHUB_OUTPUT=str(output))

            def render(script, affected=''):
                return (script.replace('${{ needs.determine_changed_files.outputs.all_changed_files }}', changed)
                        .replace('${{ github.event_name }}', event)
                        .replace('${{ env.AFFECTED_KERNEL_VERSIONS }}', affected))

            subprocess.run(['bash', '-e', '-o', 'pipefail', '-c',
                            render(workflow_script('Determine Affected Kernel Versions'))],
                           env=env, check=True, capture_output=True)
            affected = output.read_text().split('=', 1)[1].strip()
            output.unlink()
            subprocess.run(['bash', '-e', '-o', 'pipefail', '-c',
                            render(workflow_script('Set targets'), affected)],
                           env=env, check=True, capture_output=True)
            return dict(line.split('=', 1) for line in output.read_text().splitlines())

    def test_driver_change_includes_default_and_testing_kernels(self):
        matrix = json.loads(self.matrix('push', 'package/kernel/r8101/Makefile')['targets_subtargets'])
        self.assertEqual(len(matrix), 3)
        self.assertIn({'target': 'x86', 'subtarget': '64', 'testing': '6.18'}, matrix)

    def test_helper_change_runs_all_kernels(self):
        matrix = json.loads(self.matrix('push', '.github/workflows/scripts/ci_downloads.py')['targets_subtargets'])
        self.assertEqual(len(matrix), 3)

    def test_version_specific_change_keeps_version_filter(self):
        matrix = json.loads(self.matrix('push', 'target/linux/generic/hack-7.2/test.patch')['targets_subtargets'])
        self.assertEqual(matrix, [{'target': 'x86', 'subtarget': '64'}])

    def test_dispatch_ignores_change_filter_and_deduplicates_kernels(self):
        matrix = json.loads(self.matrix('workflow_dispatch', '')['targets_subtargets'])
        self.assertEqual(len(matrix), 3)


if __name__ == '__main__':
    unittest.main()
