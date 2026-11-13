# Six-Lane Regression Scheduling

Batch: 20261107T181004Z-3761310 (114 firmware-scope combinations).
Queue service: agw-six-regression.service.
CPU allocator: agw-cpu-budget-70.service, 70 logical CPU quota budget.

Six active builds get quotas 12,12,12,12,11,11. Existing Make jobservers
are not restarted merely to change their sizes. CPU quota is not clock
frequency and does not guarantee full utilization during serial stages.
No firmware, frequency, voltage or thermal-protection settings changed.

Matrix workers use 12 GiB memory caps without swap. The two repair units
remain separately reserved while active. Admission allows four matrix
workers plus two repairs, then five plus one repair, then six matrix
workers. At launch MIPS repairs had ended and Rust host remained active.
LLVM host and target compilation had passed in the repair workspace.

LLVM/Rust Ninja paths share two cross-container lock slots and use -j4.
Ninja caller job flags cannot override that limit. Normal Ninja graphs
share GNU Make FIFO tokens. Rust bootstrap and Cargo stay at two jobs.
Tests passed for six heavy requests with peak concurrency two, and for
resource admission rejecting memory/CPU overcommit.

The previous matrix was cancelled, not passed. Its two workspaces and
private tools volumes were moved/reused only after exact product source,
feed lock, scope and toolchain digest checks. Product fingerprint includes
tracked and new files, modes and symlinks, independent of index staging.
Performance-only control files are excluded. Reuse was confirmed for x86
and MIPS via each job's reused-workspace.env and host-tools-cache.txt.

No full combination has yet passed in this new batch; duration is not
measured. At six effective workers, an assumed 6-12 hours per combination
would mean 4.75-9.5 days before additional repairs/retests. This is only a
scenario estimate, not observed throughput or a completion commitment.
Production .config is unchanged. No commit or push performed.
