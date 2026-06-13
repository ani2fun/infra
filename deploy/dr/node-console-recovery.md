# Node recovery — when a node is unreachable (e.g. wk-1 down)

What to do when a node stops responding over the network, like the **2026-06-13
wk-1 wedge** (a runaway process drove it into node-wide OOM and it hung for ~7h
until a manual power-cycle). Ordered from least to most invasive — stop as soon as
one step gets you in.

> **First, the good news:** every node now has `vm.panic_on_oom=1` + `kernel.panic=10`
> (see `deploy/bootstrap/host-prep/sysctl/20-oom-resilience.conf`), so a node that
> exhausts memory **reboots itself in ~10 s**. The steps below are the fallback for
> when that doesn't fire (a true hang, a network fault, or a hardware issue).

Reference addresses (from `deploy/inventory/`):

| Node | LAN IP | WireGuard IP |
|------|--------|--------------|
| ms-1 (control plane) | 192.168.15.12 | 172.27.15.12 |
| wk-1 (DB) | 192.168.15.3 | 172.27.15.11 |
| wk-2 | 192.168.15.13 | 172.27.15.13 |
| ctb-edge-1 | — (cloud) | 172.27.15.31 |

## 1. Triage from the network (bottom-up)

```bash
# From your laptop:
ping -c2 192.168.15.3            # LAN reachable at all?
ssh wk-1 'uptime; free -h'       # SSH over LAN

# From ms-1 (tests the WireGuard mesh + cluster view):
ssh ms-1 'ping -c2 172.27.15.11; kubectl get node wk-1 -o wide'
ssh ms-1 'wg show all latest-handshakes'   # recent handshake = WG alive
```

- **SSH works** → you're in; jump to §3 (diagnose) without touching hardware.
- **LAN pings but SSH hangs** → host is alive but wedged (likely OOM/IO). Go to §2,
  then §4 (SysRq reboot).
- **Nothing responds on LAN or WG** → host is hung or off. Go to §2 (physical console).

## 2. Physical console access (the "minimal server GUI")

wk-1 is now a **headless server** (no desktop). Its console is a **text login on
tty1** — that *is* the minimal GUI. To reach it:

1. Plug a **monitor** into the node's HDMI/DisplayPort and a **USB keyboard**.
2. You should see a text login prompt (`wk-1 login:`). If the screen is blank or on
   a different VT, press **Ctrl+Alt+F1** … **F6** to switch virtual terminals, or tap
   a key to wake the display.
3. Log in as `root` (or `aniket`, then `sudo -i`).
4. If the prompt accepts input, the kernel is alive — go to §3. If keystrokes do
   nothing at all, the kernel is hung — go straight to §4.

> No spare monitor? These are mini-PCs — any TV + a $5 USB keyboard works. Keep one
> in the homelab kit. (A USB-serial console is the pro option but not wired up here.)

## 3. Diagnose at the console (or over SSH if you got in)

```bash
uptime; free -h; swapon --show          # memory state (swap is intentionally off)
journalctl -k -b -1 | grep -iE 'oom|killed process|panic|hung'   # last boot's OOM?
journalctl -b -1 -e                     # tail of the boot that died
systemctl status k3s-agent NetworkManager   # core services
ip a; nmcli device                      # networking (NetworkManager-managed here)
top -o %MEM                             # what's eating RAM right now
```

If it was OOM: find the offender (`session-c1.scope` was the GNOME session on
2026-06-13; a loaded `ollama` model is the other likely culprit). Bound or stop it.

## 4. Safe reboot of a wedged node — Magic SysRq (do NOT just pull power)

The node-local Postgres data lives on wk-1's disk, so a hard power cut risks
corruption. SysRq is now enabled (`kernel.sysrq=1`), which lets you ask the kernel
to flush and reboot **cleanly** even when userspace is hung. On the physical
keyboard, hold **Alt + SysRq** (SysRq = the **PrtSc** key) and press, one at a time,
a few seconds apart:

```
R  E  I  S  U  B
```

Mnemonic *"Reboot Even If System Utterly Broken"*: **R**aw keyboard, t**E**rminate,
k**I**ll, **S**ync disks, **U**nmount read-only, re**B**oot. The S and U steps are
what protect the database. If `Alt+SysRq` is intercepted, try **Alt+Fn+PrtSc** on
laptop-style keyboards.

**Only if SysRq does nothing** (totally hung kernel): hard power-cycle (hold power
10 s, or pull power). Expect Postgres to run crash recovery on next start — that's
normal and usually clean.

## 5. After it comes back

```bash
ssh ms-1 'kubectl get nodes'                                  # wk-1 Ready?
ssh ms-1 'kubectl -n databases-prod get pod postgresql-0 -o wide'   # DB back, Running
ssh ms-1 'kubectl get pods -A | grep -vE "Running|Completed"' # anything stuck?
```

Postgres, go-judge, and (dependent) cortex recover on their own once wk-1 rejoins.
Then capture *why* it went down (§3) and close the gap — that's the point of
`deploy/bootstrap/host-prep/` hardening, not just rebooting and moving on.
