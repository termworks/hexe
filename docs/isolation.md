# Hexe Isolation Guide

Complete guide to process, resource, and filesystem isolation in Hexe using [libvoid](https://github.com/bresilla/libvoid).

## Overview

Hexe uses **libvoid** for Linux sandboxing with three types of isolation:

1. **Process Isolation** - Namespaces (user, PID, mount, network, UTS, IPC)
2. **Resource Isolation** - Cgroups (CPU, memory, process limits)
3. **Filesystem Isolation** - Chroot-style bind mounts with private /tmp

Filesystem isolation works by creating a **chroot-style environment** using bind mounts inside a mount namespace. Instead of the traditional `chroot()` syscall, libvoid selectively bind-mounts only the directories each profile needs into a fresh mount namespace — giving you a restricted root filesystem view without the security pitfalls of classic chroot.

## Isolation Profiles

### `none` (Default)
**No isolation** - Normal operation with full system access.

- ❌ No namespaces
- ❌ No resource limits
- ❌ No filesystem restrictions
- ✅ Full access to all processes, files, network

**Use case**: Trusted code, normal shell work

---

### `minimal`
**Light isolation** - Basic privilege separation.

**Process:**
- ✅ User namespace (different UID/GID mapping)

**Filesystem:**
- ❌ No filesystem isolation (no bind mounts, no private /tmp)

**Use case**: Basic privilege separation, semi-trusted tools

**What you'll see:**
```bash
whoami           # Different UID mapping
ls /             # Full filesystem (no restrictions)
```

---

### `default` / `balanced`
**Process + mount isolation** - Chroot-style filesystem with separate mount table.

> `default` and `balanced` are equivalent profiles.

**Process:**
- ✅ User namespace
- ✅ PID namespace (can't see other processes)
- ✅ Mount namespace (separate mount table)

**Filesystem (chroot-style bind mounts):**
- ✅ Private `/tmp` (tmpfs)
- ✅ Read-only: `/bin`, `/usr`, `/lib`, `/lib64`, `/etc`
- ✅ Read-only: `/nix`, `/pkg`, `/opt`, `/run/current-system` (package managers)
- ✅ Read-write: Your `/home/<user>` directory
- ✅ Fresh `/proc`, `/dev`

**Use case**: Isolated environment for development/testing

**What you'll see:**
```bash
ps aux           # Only shows processes in this pane!
ls /home         # Only your user directory
ls /             # Only: bin, usr, lib, etc, nix, pkg, opt, home/<you>, tmp
mount            # Separate mount table (mounts don't leak to host)
```

---

### `sandbox` (Recommended for untrusted code)
**Full isolation WITH network** - Secure but functional.

**Process:**
- ✅ User namespace
- ✅ PID namespace
- ✅ Mount namespace
- ❌ Network namespace (network allowed!)
- ✅ UTS namespace (hostname set to `hexe`)
- ✅ IPC namespace (isolated shared memory)

**Security:**
- ✅ `no_new_privs` (can't escalate privileges)
- ✅ Capabilities dropped

**Filesystem (chroot-style bind mounts):**
- ✅ Private `/tmp` (tmpfs)
- ✅ Read-only: `/bin`, `/usr`, `/lib`, `/lib64`, `/etc`
- ✅ Read-only: `/nix`, `/pkg`, `/opt`, `/run/current-system` (package managers)
- ✅ Read-write: Your `/home/<user>` directory
- ✅ Fresh `/proc`, `/dev`

**Resources** (if configured):
- ✅ Memory limit (e.g., 512M)
- ✅ CPU limit (e.g., 0.5 cores)
- ✅ Process limit (e.g., 100 PIDs)

**Use case**: Run untrusted code that needs internet (downloading packages, API calls)

**What you'll see:**
```bash
ps aux                # Only this pane's processes
curl example.com      # Network works!
ls /                  # Only: bin, usr, lib, etc, nix, pkg, opt, home/<you>, tmp
touch /tmp/test       # Private tmp
hostname              # "hexe" (isolated hostname)
```

---

### `full`
**Maximum isolation** - Restricted access, no network.

**Process:**
- ✅ User namespace
- ✅ PID namespace
- ✅ Mount namespace
- ✅ **Network namespace (NO NETWORK!)**
- ✅ UTS namespace (hostname set to `hexe`)
- ✅ IPC namespace

**Security:**
- ✅ `no_new_privs` (can't escalate privileges)
- ✅ Capabilities dropped

**Filesystem (chroot-style bind mounts):**
- ✅ Private `/tmp` (tmpfs)
- ✅ Read-only: `/bin`, `/usr`, `/lib`, `/lib64`, `/etc`
- ❌ NO `/nix`, `/pkg`, `/opt`, `/run/current-system`
- ✅ Read-write: Your `/home/<user>` directory
- ✅ Fresh `/proc`, `/dev`

**Resources** (if configured):
- ✅ Memory limit
- ✅ CPU limit
- ✅ Process limit

**Use case**: Maximum security for highly untrusted code

**What you'll see:**
```bash
ps aux                # Only this pane's processes
ping 8.8.8.8          # Network unreachable!
ls /                  # Only: bin, usr, lib, lib64, etc, home/<you>, tmp
curl example.com      # Fails - no network
```

---

## Usage

### 1. Command-line (Ad-hoc floats)

```bash
# Spawn isolated float with sandbox profile
hexe terminal float --command "zsh" --isolation=sandbox

# Full isolation (no network, minimal filesystem)
hexe terminal float --command "zsh" --isolation=full

# With size and title
hexe terminal float --command "zsh" \
  --isolation=sandbox \
  --title="Isolated Shell" \
  --size "80,60,0,0"

# Run untrusted script
hexe terminal float --command "bash /tmp/untrusted.sh" --isolation=full
```

### 2. Configuration (Per-float in init.lua)

Configure isolation for specific floats in your `~/.config/hexe/init.lua`:

```lua
hx.ses.layout.define({
  name = "default",
  floats = {
    {
      key = "0",
      enabled = true,
      title = "sandbox",
      isolation = {
        profile = "sandbox",  -- Isolation profile
        memory = "512M",      -- Memory limit
        pids = 100,           -- Max processes
        cpu = "50000 100000", -- 0.5 CPU cores
      },
    },
  },
})
```

**Isolation fields:**
- `profile`: Profile name (`none`, `minimal`, `default`/`balanced`, `sandbox`, `full`)
- `memory`: Memory limit (e.g., "1G", "512M", "256M") — sandbox/full only
- `cpu`: CPU quota as "period max" (e.g., "100000 100000" = 1 core, "50000 100000" = 0.5 cores) — sandbox/full only
- `pids`: Maximum number of processes (e.g., 100, 1000) — sandbox/full only

---

## Resource Limits (Cgroups)

Control CPU, memory, and process limits:

### Memory Limit

```bash
# 512MB limit
hexe terminal float --command "zsh" --isolation=sandbox  # Uses config

# In Lua config:
isolation = {
  profile = "sandbox",
  memory = "512M",  -- Killed if exceeded
}
```

**Test it:**
```bash
# This will be killed when it exceeds 512M
python3 -c "a = 'x' * (1024**3)"  # Try to allocate 1GB
```

### CPU Limit

```bash
# 0.5 cores max
isolation = {
  profile = "sandbox",
  cpu = "50000 100000",  -- 50% of one core
}
```

**Format:** `period max`
- `"100000 100000"` = 1 full core
- `"50000 100000"` = 0.5 cores
- `"200000 100000"` = 2 cores

### Process Limit

```bash
# Max 100 processes
isolation = {
  profile = "sandbox",
  pids = 100,
}
```

**Test it:**
```bash
# This will fail after 100 forks
:(){ :|:& };:  # Fork bomb (safely contained!)
```

---

## Filesystem Isolation Details

Profiles with mount namespace (`default`/`balanced`, `sandbox`, `full`) use **chroot-style bind mounts** to construct a restricted root filesystem. Only explicitly listed directories are visible inside the isolated pane.

### Bind Mounts (Read-only vs Read-write)

**Read-only mounts** (safe, can't modify):
- `/bin`, `/usr`, `/lib`, `/lib64`, `/etc` - System binaries and configuration
- `/nix`, `/pkg`, `/opt`, `/run/current-system` - Package managers (not in `full`)

**Read-write mounts** (you can modify):
- `/home/<youruser>` - Your home directory

**Fresh mounts** (generated per-pane):
- `/tmp` - Private tmpfs
- `/proc` - Namespace-filtered process list
- `/dev` - Filtered device nodes

> **Note**: `minimal` has NO filesystem isolation — it only creates a user namespace.

### What's Hidden?

In chroot-style isolation, only bind-mounted paths exist. These are **not visible**:

- `/root` - Root home directory
- `/home/<otheruser>` - Other users' home directories
- `/sys` - System information
- `/var`, `/srv`, `/mnt` - Other system directories
- `/proc` shows only your processes (PID namespace)

### Private /tmp

Every isolated pane (except `minimal`) gets its own `/tmp` via tmpfs:

```bash
# Pane 1:
touch /tmp/secret.txt
ls /tmp              # Shows secret.txt

# Pane 2 (isolated):
ls /tmp              # Empty! Can't see Pane 1's files
```

---

## Examples

### Example 1: Isolated Development Environment

```bash
hexe terminal float --command "zsh" \
  --isolation=sandbox \
  --title="Dev Sandbox"

# Inside:
npm install   # Network works, downloads packages
ls /tmp       # Private temp directory
ps aux        # Only sees npm processes
```

### Example 2: Running Untrusted Code

```bash
# Full isolation - no network, restricted filesystem
hexe terminal float --command "python3 /tmp/untrusted.py" \
  --isolation=full

# The script:
# - Can't access network
# - Can't see other processes
# - Can't see /nix, /pkg, /opt
# - Limited to configured RAM (if set)
# - Can't fork bomb (PID limit)
```

### Example 3: Build Environment

```lua
-- In init.lua
{
  key = "b",
  title = "builder",
  command = "/usr/bin/make",
  isolation = {
    profile = "balanced",
    memory = "2G",
    cpu = "200000 100000",  -- 2 cores
    pids = 500,
  },
}
```

Press `Ctrl+Alt+B` to open isolated build environment.

---

## Security Considerations

### What Isolation Provides

✅ **Process containment** - Can't see/kill other processes
✅ **Resource limits** - Can't exhaust system memory/CPU (sandbox/full)
✅ **Chroot-style filesystem** - Only bind-mounted paths are visible
✅ **Network isolation** (full profile) - Can't make network connections
✅ **Privilege restriction** - `no_new_privs` prevents privilege escalation

### What Isolation Does NOT Provide

❌ **Kernel exploits** - Still shares kernel with host
❌ **Side-channel attacks** - Spectre/Meltdown not mitigated
❌ **Complete security** - Not a VM or hardware virtualization

**For maximum security**: Use VMs, containers with kernel isolation, or dedicated hardware.

---

## Troubleshooting

### Permission Denied Errors

```
[pty-child] Voidbox isolation failed: error.PermissionDenied
```

**Cause**: User namespaces disabled or insufficient permissions.

**Fix**:
```bash
# Check if user namespaces are enabled
sysctl kernel.unprivileged_userns_clone

# Enable (requires root)
sudo sysctl -w kernel.unprivileged_userns_clone=1
```

### Can't See My Files

**Issue**: Files outside `/home` are not accessible.

**Cause**: Chroot-style bind mounts only expose specific directories. Paths like `/var`, `/srv`, `/mnt` are not mounted.

**Fix**: Use `none` or `minimal` profile for full filesystem access, or add custom bind mounts.

### Network Not Working

**Issue**: `ping`, `curl` fail with "network unreachable".

**Cause**: Using `full` profile which blocks network.

**Fix**: Use `sandbox` profile for network access with isolation.

### Commands Not Found

**Issue**: `ls`, `cat`, etc. not found.

**Cause**: `/bin` not mounted (shouldn't happen with provided profiles).

**Fix**: Check profile includes `/bin` bind mount, or use `default`/`sandbox` profile.

---

## Advanced Configuration

### Custom Filesystem Actions

For advanced users, libvoid supports custom filesystem actions via environment variables (future feature) or direct libvoid configuration.

### Overlay Filesystems

Future enhancement: Use overlayfs for ephemeral root filesystem where changes don't persist between sessions.

### Network Isolation with Custom Routes

Future enhancement: Custom network namespaces with virtual interfaces for controlled internet access.

---

## Comparison with Docker/Podman

| Feature | Hexe Isolation | Docker/Podman |
|---------|---------------|---------------|
| **Startup Time** | <10ms | ~100-500ms |
| **Overhead** | Minimal | Container runtime |
| **Filesystem** | Chroot-style bind mounts | Image layers |
| **Process Isolation** | PID namespace | Full container |
| **Network** | Optional | Virtual networks |
| **Use Case** | Fast task isolation | Full application containers |

**When to use Hexe**: Quick isolation for shell tasks, scripts, development.
**When to use Docker**: Deploying applications, reproducible environments, complex networking.

---

## See Also

- [Libvoid Documentation](https://github.com/bresilla/libvoid) - Underlying sandboxing library
- [Linux Namespaces](https://man7.org/linux/man-pages/man7/namespaces.7.html) - Kernel isolation primitives
- [Cgroups v2](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html) - Resource limits
