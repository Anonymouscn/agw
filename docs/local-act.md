# Remote Docker kernel validation

Run on anonymous@192.168.2.183:

```sh
cd /data/src/openwrt
bash scripts/act-kernel.sh --list
bash scripts/act-kernel.sh           # parallel x86/64 and x86/legacy
bash scripts/act-kernel.sh 64        # x86/64 only
```

Installed dependencies: Docker Engine and act 0.2.97. Docker's data root is
/data/act/docker. The anonymous account has docker group access.
New login sessions pick up this group membership.

Each target runs act inside the corresponding official OpenWrt toolchain
image, pinned to its pulled digest for that run. Native amd64 containers
use separate cloned source trees under /data/act/runs. No production
configuration or build output directory is mounted into the container.
Tracked working-tree changes are applied to the snapshot before building;
untracked source files must be added to Git first (the act harness itself
is copied explicitly).
Only dl is shared through /cache/dl; OpenWrt download locking is retained.
Prebuilt host tools and external toolchain setup follow upstream kernel CI.

The default resource budget is 32 CPUs and 40 GiB per container. At most
two targets run per invocation. Override ACT_KERNEL_JOBS and
ACT_KERNEL_MEMORY to change the per-container budget. Independent
invocations have unique directories but share the host resource pool.

ALL_KMODS=y and KERNEL_WERROR=y are enabled from a fresh configuration.
The build commands are tools/install, toolchain/install, target/linux/clean,
target/compile and package/linux/compile. This reproduces the kernel build
and packaging checks, not GitHub's artifact uploads, cache operations,
changed-target detection or the entire multi-architecture CI matrix.

Results, source SHA, image digest, phase logs, configuration, selected kmod
list and APK inventory are retained in /var/log/agw-act/<run-id>/<target>.
Nonzero make status propagates through act to the invoking shell.
The production .config checksum is checked after all jobs complete.
Run directories are retained for diagnosis and are not automatically deleted.
Failed containers are also retained by act; they can be inspected with
docker ps -a. They are not a background build service.

For a package-only retry in a retained container, the workflow build script
supports ACT_KERNEL_STAGE=kmods and ACT_KERNEL_RECORD=/results/<attempt>.
Invoke act with --reuse and the same workspace, workflow name, image and
volume mappings as the failed run. Apply source fixes to that isolated
workspace first. This reuses compiled objects; it does not represent a new
clean kernel build. Keep both the original and retry exit codes.

The workflow is .github/act/kernel.yml, outside .github/workflows, so it
does not create an extra automatic GitHub Actions job. No GitHub token or
repository secrets are needed for these local build jobs.
