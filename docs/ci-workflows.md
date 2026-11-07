# CI workflow maintenance

The kernel and package entry points call the repository's reusable
ci-kernel.yml, ci-packages.yml and ci-build.yml workflows. These were
adapted from openwrt/actions-shared-workflows commit
35022f31a3e45a35b7bd0a82151187cb325071f6. Ancillary reusable workflows
remain pinned to that commit. Preserve their provenance comments when
updating from upstream.

Local ownership lets fixes to snapshot downloads and external driver
coverage take effect in the actual GitHub jobs. Editing only an unused
local helper would not change a reusable workflow referenced with @main.

ci_downloads.py downloads a complete SHA256 manifest once per job and
reuses it for toolchain and LLVM selection. Transfers and invalid content
are retried using temporary files and atomic publication. Extraction
requires the original OpenWrt signing keys, a valid detached signature
for that exact manifest, and the archive's matching SHA256 checksum.
An absent optional LLVM archive is distinct from a failed download.

Run the helper regression tests with:

```sh
python3 -m unittest discover -s .github/workflows/scripts/tests -v
```

Tests simulate truncated transfers, HTTP failures, invalid manifests,
archive corruption and signature failures. They also check selected
external module discovery. Kernel and package workflows run these tests
before their build matrices.

When updating reusable workflows, compare against the recorded upstream
commit, retain the local download and external-module steps, update pinned
references consistently, run the tests and actionlint, then validate with
the remote Docker/act environment described in local-act.md. Kernel jobs
with build_all_kmods compile the selected external module sources after
the in-tree packages. Full userspace and image builds still require world.
