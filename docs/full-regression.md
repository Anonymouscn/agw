# Regression coverage

The full matrix follows the stable and testing kernel declarations for every
target/subtarget. x86 keeps Linux 7.2 as its default and tests its retained
6.18 configuration as the alternate. The current matrix contains 114 jobs:
29 with 6.12.107, 81 with 6.18.44, and four with 7.2.3. The scripts regenerate
this list from source; these counts are not hardcoded. A config file alone
does not declare support for another target/kernel combination.

The historical 110-job kernel run covered target/compile and in-tree module
packaging. The subsequent x86/64 Linux 7.2.3 run verified 1163 kmod APKs and
the selected external drivers. Neither run is a full userspace/feed build.

## Full package and image modes

GitHub's **Full kernel and package regression** workflow is manually
dispatched. It preserves the faster PR workflows. Select `packages` for
all selectable core/feed packages and modules, or `firmware` to additionally
build all selected device profiles and verify their declared image files.
By default it includes every declared kernel/target combination and all six
configured feeds. A target/kernel filter is available for retries.

The same modes run in isolated Docker/act workspaces on the remote builder:

```sh
cd /data/src/openwrt
bash scripts/act-regression.sh --all
bash scripts/act-regression.sh --status
# A targeted rerun:
bash scripts/act-regression.sh x86/64@7.2
# Include image generation:
ACT_REGRESSION_SCOPE=firmware bash scripts/act-regression.sh --all
```

Full modes default to two containers, 32 GiB per container and 24 make jobs;
host tools remain capped at eight. The kernel-only entry retains its earlier
defaults. One queue lock prevents overlapping batches. Resume retains the
frozen source, scope, feeds lock and recorded toolchain digests. The disk
guard stops launching jobs when space is insufficient; this is not PASS.
Jobs time out after 24 hours (ACT_REGRESSION_JOB_TIMEOUT overrides this),
with a distinct FAIL_TIMEOUT result. Cargo and CMake parallelism is capped
at the host-tool budget; Go uses the make-job budget.
Production `.config` and feed checkouts are not reset by builds.

Package mode sets `CONFIG_ALL=y`, `CONFIG_ALL_KMODS=y` and kernel WERROR.
It runs `make package/compile -k IGNORE_ERRORS=` after the kernel build.
Keep-going gathers independent failures while preserving a failing exit
status. This includes selected userspace packages, core/external/feed
modules and the package variants selected by Kconfig. Host dependencies
build as part of that dependency graph. The SDK compiler is reused; this
does not rebuild every GCC/Clang toolchain from source.

## Reproducible feeds

`.github/regression/feeds.lock.json` records all configured feeds, exact
commit hashes, and local tracked/untracked source fixes. Overlay checksums
are verified before application. Restoring refuses an existing checkout.
Feed indexing uses `feeds update -i`, which does not update locked revisions.
This includes packages, luci, routing, telephony, video and helloworld.

After intentionally updating and reviewing the developer feed trees,
refresh the lock and review its diff:

```sh
python3 .github/act/feed-lock.py capture --lock .github/regression/feeds.lock.json
python3 .github/act/feed-lock.py validate --lock .github/regression/feeds.lock.json
```

The captured netatop source patch had incorrect hunk counts; those were
corrected and dry-run against netatop 3.1. Its original form is retained
under `/var/log/agw-act/coverage-20261107/`.

## Evidence and remaining limits

Each job stores the final config, actual compiled kernel release, package
metadata, selected/unselected package definitions, build exit code, and
actual APK names, ABI tags, origins, versions, architectures and SHA256s.
Positive dependency providers and version constraints are checked against
those APKs; native apk version comparison is used. Install-time conflicts
between alternative packages are still a separate test scope.
The auditor handles ABI-renamed libraries and feed source symlinks. A
missing selected APK fails strict coverage. Build-only packages are marked
separately because they do not produce APKs. Image mode checks profiles.json
entries, selected profile IDs and image hashes; it is not a boot test.

The GitHub summary and remote `coverage-summary.json` distinguish missing
jobs, failures, wrong kernels and definitions never selected by any job.
Unselected dependency/provider cases are not counted as passed. Per-job
reports are under `coverage/` locally and `regression-results/` in GitHub
artifacts. The batch also retains source diffs, feed revisions, toolchain
digests, timings and phase logs in `/var/log/agw-act/<batch-id>/`.

Even a passing compile matrix does not cover:

- Every mutually exclusive provider, package feature or Kconfig combination.
  `never_selected` identifies installed catalog definitions needing review.
- Shadowed feed definitions that are not installed in the project's catalog.
- Production-profile boot on BIOS/UEFI, actual peripherals, services and upgrades.
- Every upstream unit/integration test, fuzz test, sanitizer or performance test.
- Alternative compiler versions, libc variants, or undeclared kernel ports.

These are explicit gaps, not N/A successes. Additional configuration and
runtime suites should be added for the hardware and production profiles
actually supported by the project.

## Feed configuration preflight fixes

Full feed indexing exposed Kconfig recursion in LibreSpeed's virtual
backend selection and squeezelite's optional FFmpeg dependency. The fixes
are retained both in the feeds lock and local patch 007, registered in
patch.sh. LibreSpeed common now requires an explicitly selected Go or Rust
backend; both remain available. Squeezelite's WMA option selects FFmpeg in
Kconfig and adds its runtime dependency when enabled. The real preflight
tested each backend, the WMA option and the x86 6.18 configuration.
Patch 008 removes a redundant BuildPackage call in luci-app-rustdesk-server;
luci.mk already performs that call, and the extra call duplicated metadata.

check-config.py rejects parser errors even if make defconfig returns zero.
Warnings and unsupported dependencies remain visible in the evidence.
