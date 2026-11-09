import collections
import hashlib
import http.server
import importlib.util
import io
import os
import pathlib
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[4]
SCRIPT = ROOT / '.github/workflows/scripts/ci_downloads.py'


class DownloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys = tempfile.TemporaryDirectory()
        os.chmod(cls.keys.name, 0o700)
        cls.gpg_env = dict(os.environ, GNUPGHOME=cls.keys.name)
        subprocess.run(['gpg', '--batch', '--pinentry-mode', 'loopback', '--passphrase', '',
                        '--quick-generate-key', 'ci-test@example.invalid', 'ed25519', 'sign', '0'],
                       env=cls.gpg_env, check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        subprocess.run(['gpgconf', '--kill', 'gpg-agent'], env=cls.gpg_env, capture_output=True)
        cls.keys.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.cache = self.root / 'cache'
        self.archive = 'openwrt-toolchain-test.tar.xz'
        self.llvm = 'llvm-bpf-test.tar.xz'
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w:xz') as output:
            content = b'correct toolchain\n'
            item = tarfile.TarInfo('toolchain/probe.txt')
            item.size = len(content)
            output.addfile(item, io.BytesIO(content))
        self.payload = buffer.getvalue()
        digest = hashlib.sha256(self.payload).hexdigest()
        self.body = '{} *{}\n{} *{}\n'.format(digest, self.archive, digest, self.llvm).encode()
        self.signature = self.sign(self.body)
        self.counts = collections.Counter()
        self.truncate = 0
        self.truncate_archive = 0
        self.ranges = []
        self.corrupt_archive = 0
        self.fail_manifest = False
        self.bad_signature = False
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                fixture.counts[self.path] += 1
                if self.path == '/sha256sums':
                    if fixture.fail_manifest:
                        self.send_error(503)
                        return
                    body = fixture.body
                    if fixture.counts[self.path] <= fixture.truncate:
                        self.send_response(200)
                        self.send_header('Content-Length', str(len(body)))
                        self.end_headers()
                        self.wfile.write(body[:len(body) // 2])
                        self.wfile.flush()
                        self.connection.shutdown(socket.SHUT_WR)
                        self.close_connection = True
                        return
                elif self.path == '/sha256sums.asc':
                    body = b'invalid signature' if fixture.bad_signature else fixture.signature
                elif self.path in ('/' + fixture.archive, '/' + fixture.llvm):
                    body = fixture.payload
                    if fixture.counts[self.path] <= fixture.corrupt_archive:
                        body = b'corrupt archive'
                    range_header = self.headers.get('Range')
                    if range_header:
                        fixture.ranges.append(range_header)
                        start = int(range_header.removeprefix('bytes=').removesuffix('-'))
                        self.send_response(206)
                        self.send_header('Content-Range', 'bytes {}-{}/{}'.format(
                            start, len(body) - 1, len(body)))
                        self.send_header('Content-Length', str(len(body) - start))
                        self.end_headers()
                        self.wfile.write(body[start:])
                        return
                    if fixture.counts[self.path] <= fixture.truncate_archive:
                        self.send_response(200)
                        self.send_header('Content-Length', str(len(body)))
                        self.end_headers()
                        self.wfile.write(body[:len(body) // 2])
                        self.wfile.flush()
                        self.connection.shutdown(socket.SHUT_WR)
                        self.close_connection = True
                        return
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = 'http://127.0.0.1:{}/sha256sums'.format(self.server.server_port)
        self.env = dict(self.gpg_env, CI_DOWNLOAD_ATTEMPTS='3', CI_DOWNLOAD_DELAY='0')

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def sign(self, body):
        return subprocess.check_output(['gpg', '--batch', '--yes', '--armor', '--detach-sign'],
                                       input=body, env=self.gpg_env, stderr=subprocess.DEVNULL)

    def cli(self, *args, success=True):
        result = subprocess.run([sys.executable, str(SCRIPT), *args, '--url', self.url,
                                 '--cache', str(self.cache)], cwd=self.root,
                                env=self.env, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr.decode())
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def select(self, kind='toolchain', success=True, external=None):
        return self.cli('select', '--kind', kind,
                        '--external-toolchain', str(external or self.root / 'absent'),
                        '--env', str(self.root / 'env'), '--output', str(self.root / 'output'),
                        success=success)

    def test_partial_manifest_retried_and_shared_between_selections(self):
        self.truncate = 2
        self.select()
        self.select('llvm')
        self.assertEqual(self.counts['/sha256sums'], 3)
        self.assertIn('TOOLCHAIN_FILE=' + self.archive, (self.root / 'env').read_text())
        self.assertIn('LLVM_FILE=' + self.llvm, (self.root / 'env').read_text())
        self.assertFalse(list(self.cache.glob('*.part')))

    def test_persistent_network_failure_does_not_emit_outputs(self):
        self.fail_manifest = True
        self.select(success=False)
        self.assertEqual(self.counts['/sha256sums'], 3)
        self.assertFalse((self.root / 'env').exists())
        self.assertFalse(list(self.cache.glob('*.sha256sums')))

    def test_html_response_is_rejected(self):
        self.body = b'<html>unavailable</html>'
        self.select(success=False)
        self.assertFalse((self.root / 'output').exists())

    def test_sdk_fallback_and_optional_llvm(self):
        self.body = ('1' * 64 + ' *openwrt-sdk-test.tar.zst\n').encode()
        self.select()
        self.select('llvm')
        self.assertIn('toolchain-type=external_sdk', (self.root / 'output').read_text())
        self.assertIn('LLVM_FILE=\n', (self.root / 'env').read_text())
        self.assertEqual(self.counts['/sha256sums'], 1)

    def test_external_container_does_not_suppress_llvm_selection(self):
        external = self.root / 'external'
        external.mkdir()
        self.select(external=external)
        self.assertEqual(self.counts['/sha256sums'], 0)
        self.select('llvm')
        self.assertIn('llvm-type=external', (self.root / 'output').read_text())

    def test_ambiguous_artifacts_are_rejected(self):
        self.body += ('1' * 64 + ' *openwrt-toolchain-other.tar.zst\n').encode()
        self.select(success=False)
        self.assertFalse((self.root / 'env').exists())

    def test_signed_archive_retries_checksum_mismatch_before_extracting(self):
        self.select()
        self.corrupt_archive = 1
        self.cli('extract', '--artifact', self.archive)
        self.assertEqual(self.counts['/' + self.archive], 2)
        self.assertEqual(self.counts['/sha256sums'], 1)
        self.assertEqual((self.root / 'toolchain/probe.txt').read_text(), 'correct toolchain\n')

    def test_interrupted_archive_download_resumes_with_range(self):
        self.select()
        self.truncate_archive = 1
        self.cli('extract', '--artifact', self.archive)
        self.assertEqual(self.counts['/' + self.archive], 2)
        self.assertEqual(self.ranges, ['bytes={}-'.format(len(self.payload) // 2)])
        self.assertEqual((self.root / 'toolchain/probe.txt').read_text(), 'correct toolchain\n')

    def test_bad_signature_never_downloads_or_extracts_archive(self):
        self.select()
        self.bad_signature = True
        self.cli('extract', '--artifact', self.archive, success=False)
        self.assertEqual(self.counts['/' + self.archive], 0)
        self.assertFalse((self.root / 'toolchain').exists())

    def test_archive_traversal_is_rejected(self):
        self.cli('extract', '--artifact', '../' + self.archive, success=False)
        self.assertFalse(self.counts)


class ExternalModuleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('external_kmods', ROOT / '.github/act/external-kmods.py')
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_selects_all_separate_sources_and_deduplicates_variants(self):
        config = '\n'.join('CONFIG_PACKAGE_{}=m'.format(n) for n in
                           ('kmod-r8101', 'kmod-driver-rss', 'kmod-driver', 'kmod-libphy'))
        metadata = '''Source-Makefile: package/kernel/r8101/Makefile
Package: kmod-r8101
Source-Makefile: package/kernel/driver/Makefile
Package: kmod-driver
Package: kmod-driver-rss
Source-Makefile: package/kernel/linux/Makefile
Package: kmod-libphy
Source-Makefile: package/kernel/unselected/Makefile
Package: kmod-unselected
'''
        self.assertEqual(self.module.targets(config, metadata),
                         ['package/kernel/driver/compile', 'package/kernel/r8101/compile'])

    def test_missing_metadata_is_a_failure(self):
        with self.assertRaises(ValueError):
            self.module.targets('CONFIG_PACKAGE_kmod-r8101=y', '')

    def test_unsafe_source_path_is_a_failure(self):
        with self.assertRaises(ValueError):
            self.module.targets('CONFIG_PACKAGE_kmod-r8101=y',
                                'Source-Makefile: package/../outside/Makefile\nPackage: kmod-r8101')


if __name__ == '__main__':
    unittest.main()
