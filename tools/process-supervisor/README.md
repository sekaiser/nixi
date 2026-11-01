# Captured-command supervisor

This small Nix-built C helper owns the lifecycle of Hey's **noninteractive**
captures on Linux and macOS. Foreground execution, terminal job control, tmux
and interactive SSH sessions do not use it. No third-party runtime is required.

The helper creates a new process group before executing the command. It preserves
argv, environment, cwd and exit status without shell interpolation. Command stdin
is `/dev/null`. stdout and stderr are captured separately, with per-stream byte
limits; `--inherit-stderr` streams stderr without buffering or limiting it.

On timeout, overflow, cancellation **or normal command exit**, it sends TERM and
CONT to the group, waits 100 ms, then sends KILL. It also kills the direct child if
that child left its group. The direct child remains unreaped until the last group
signal, reserving its PID and preventing a recycled group ID from being signalled.
On macOS, an EPERM result can mean a zombie-only group: a bounded kernel-filtered
group snapshot disambiguates this from a real permission failure. The snapshot
never supplies individual signal targets; no ancestry scan is used for cleanup.

The caller owns the only write end of a private control pipe connected to helper
stdin. Closing it (including kernel closure on abrupt caller death), or writing
any byte, requests cancellation. Janet execs do not inherit other captures'
control writers. The command never receives the control pipe. Cancellation
abandons protocol delivery, so a dead or stalled reader cannot block cleanup.
Captured buffers are bounded in both the helper and Janet bridge. Cleanup still
runs while protocol delivery is backpressured.

This is lifecycle management, **not a security sandbox**. Descendants deliberately
using `setsid`/`setpgid`, work handed to an existing daemon, and processes outside
the caller's signal permissions are not contained. SIGKILL cannot force immediate
exit from an uninterruptible kernel operation; killing the supervisor itself with
SIGKILL also prevents its cleanup. No privileged service, Linux cgroup or macOS
launchd job is installed. Detached workers need a dedicated service boundary.

After KILL, direct-child waiting is bounded to two seconds from cleanup start.
After reaping, inherited output pipes must reach EOF within 250 ms, and final
delivery must finish within one second. Failures are reported, not silently
accepted as successful truncated output. The helper reaps its direct child;
orphan descendants are reaped by the OS's designated reaper.

## Private protocol, version 1

Invocation: `nixi-process-supervisor --limit BYTES --timeout SECONDS
[--inherit-stderr] -- COMMAND ARG...`. Zero timeout means no deadline.
`--protocol-version` prints `1`. stdin must be a pipe.

stdout begins with `NXSP1\n`, followed by frames: one ASCII tag, four-byte
big-endian unsigned payload length, then payload. `O`/`E` carry raw stdout/stderr
bytes (at most 65536 per frame). One terminal `R` frame contains ASCII integers
`status reason errno`. Reasons are:

| Reason | Meaning | Status |
| --- | --- | --- |
| 0 | Command exit | Command's status, or 128 + signal |
| 1 | Timeout | 124 |
| 2 | Output limit exceeded | 125 |
| 3 | Cancellation | Not delivered when the owner disappears |
| 4 | Command setup/exec failed | 127, with errno |
| 5 | Supervision failure | 125, errno when available |

The helper exits zero after delivering a result; command failure is represented
in the result, not confused with helper failure. Setup/delivery failure may exit
125 without a complete result, which Janet rejects. Timeout/overflow results
discard accumulated command output in Janet. stderr is reserved for helper
diagnostics except when target stderr is explicitly inherited. The protocol is
internal, not a stable public API.

Regression fixtures live in `test_tools/test_process_supervisor.py`, outside
runtime tools. Run `nix build .#checks.SYSTEM.process-supervisor`; the public CI
matrix runs this native check on both Linux and macOS.
