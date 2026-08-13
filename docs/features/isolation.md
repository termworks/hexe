# Isolation

A pane can be a sandbox. Not a container image and not a VM — the pane's process is started inside
Linux namespaces with a bind-mounted root and, where the system allows it, a cgroup that caps its
memory, CPU and process count. It is one attribute on a float, or one flag on the command line.

```lua
hexe.float("sandbox", {
  key = "0",
  title = "sandbox",
  isolation = { profile = "sandbox", memory = "512M", pids = 100, cpu = "50000 100000" },
}),
```

```sh
hexe terminal float --command bash --isolation sandbox
hexe terminal float --command "bash /tmp/untrusted.sh" --isolation full
```

<!-- demo:begin -->
[![isolation demo](https://asciinema.org/a/1262982.svg)](https://asciinema.org/a/1262982)
<!-- demo:end -->

## How it works

Isolation is [libvoid](https://github.com/bresilla/libvoid) applied to the pod's child. A profile
chooses three things — which namespaces, which filesystem view, and which limits:

```
profile ──┬── namespaces   user · pid · mount · net · uts · ipc
          ├── filesystem   bind mounts into a fresh mount namespace + private /tmp
          └── cgroup       memory.max · cpu.max · pids.max
```

The filesystem is not `chroot()`. Inside a fresh mount namespace, libvoid bind-mounts only what the
profile needs — read-only system directories, a writable home, a fresh `/proc` and `/dev`, and a
tmpfs `/tmp` — which gives a restricted root view without the escape routes classic chroot has.

| profile | namespaces | filesystem | network |
|---|---|---|---|
| `none` | — | the machine's | yes |
| `minimal` | user | the machine's | yes |
| `default` / `balanced` | user, pid, mount | bind-mounted root, private `/tmp`, read-only `/bin` `/usr` `/lib` `/etc`, plus `/nix` `/pkg` `/opt` `/run/current-system` | yes |
| `sandbox` | user, pid, mount, uts, ipc | as `default` | **yes** |
| `full` | user, pid, mount, uts, ipc, **net** | as `default`, minus the package-manager paths | **no** |

`sandbox` is the one to reach for: isolated processes, isolated mount table, isolated hostname and
IPC, `no_new_privs` set — and a working network, because untrusted code that has to download
something is the common case. `full` takes the network away.

The visible difference from inside:

```sh
ps -e            # only this pane's processes (pid namespace)
hostname         # "hexe" (uts namespace)
ls /             # only what the profile mounted
touch /tmp/x     # private tmpfs; nothing leaks out
mount            # a mount table of its own
```

### Limits

```lua
isolation = {
  profile = "sandbox",
  memory  = "512M",         -- cgroup memory.max
  pids    = 100,            -- pids.max: fork bombs stop here
  cpu     = "50000 100000", -- cpu.max: 50ms per 100ms = half a core
}
```

These are cgroup v2 values written into a subtree hexe creates for the pod. They are best-effort by
design: on a system where hexe cannot create that subtree, the pane still runs with its namespaces
and no limits rather than refusing to start.

## What makes it different

tmux, screen and zellij have nothing comparable — a pane is a process, and what it can reach is
whatever your user can reach. The nearest neighbours are `bwrap`/`firejail` wrapped around a
command by hand, and the difference is where the decision lives:

- **It is a property of the pane, not of the command.** The float declares it once; everything you
  type in that float, and everything those processes spawn, is inside it.
- **It composes with the rest of a float**: per-directory instances, its own `PATH`, its own
  environment — all still apply.
- **It degrades rather than fails.** No cgroup delegation means no limits, not no pane.
- What a hand-rolled `bwrap` gives you instead: full control over every mount, and a policy you can
  read. Hexe's profiles are five fixed points, and they are not a security boundary you should bet
  a production secret on — see below.

## Configuration

Per float, in a layout:

```lua
hexe.float("build", { key = "b", command = "make", attrs = { isolated = true } }),
hexe.float("sandbox", { key = "0", isolation = { profile = "sandbox", memory = "512M" } }),
```

`attrs = { isolated = true }` is the short form (the pod's child is isolated with the default
profile); `isolation = { … }` is the long one, and it is what carries the profile name and limits.

Ad-hoc, from a shell:

| | |
|---|---|
| `--isolation <profile>` | `none`, `minimal`, `default`, `balanced`, `sandbox`, `full` |
| `--isolated` | the boolean form |

## What it cannot do

- **It needs unprivileged user namespaces, and many systems refuse them.** On Ubuntu 24.04 and
  later, AppArmor blocks them for unconfined programs by default
  (`kernel.apparmor_restrict_unprivileged_userns=1`), and every profile above `none` begins with a
  user namespace. Check with `unshare -Ur true`; if that fails, isolation cannot work as your user.
- **A float that cannot be isolated fails quietly.** The pane is rolled back and nothing is drawn:
  the reason is in the debug log (`--log debug --logfile …`), not on screen.
- **Cgroup limits need a delegated subtree.** Without one, hexe logs `AccessDenied` and the pane
  runs unlimited.
- **Capabilities are not dropped.** `no_new_privs` is set; the capability set is not reduced. This
  is a known gap, and it is the reason not to treat these profiles as a boundary against a
  determined attacker.
- **Your home is read-write in `default`, `sandbox` and `full`.** The filesystem view is narrowed,
  not emptied — untrusted code inside a sandboxed float can still write your files.
- **Linux only**, and only where `/sys/fs/cgroup` is cgroup v2.
- **Isolation applies to floats.** A tiled pane in a layout does not carry an isolation profile.

## Where it lives

| | |
|---|---|
| `src/core/isolation.zig` | profiles and their parsing |
| `src/core/isolation_voidbox.zig` | building the libvoid config, the bind-mount list, the cgroup path |
| `src/core/resource_limits.zig` | memory, cpu and pid limits |
| `src/core/pty.zig` | where the isolated child is actually spawned |
| `src/cli/commands/mux_float.zig` | `--isolation` / `--isolated` |
| `docs/isolation.md` | the long-form reference, profile by profile |
