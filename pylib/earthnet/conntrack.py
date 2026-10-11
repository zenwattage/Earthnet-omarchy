"""Connection capture for earthnet.

Three backends, tried in order:

1. ``conntrack -L``       -- the kernel's live flow table (needs root or
   CAP_NET_ADMIN). Sees all tracked TCP/UDP/ICMP flows on this host/router.
2. ``/proc/net/nf_conntrack`` -- same data, read directly (also root-only).
3. ``ss -tunH``           -- active sockets on this host only, no root. Used as
   a graceful fallback so the app is demoable unprivileged.

Each ``poll()`` returns a list of ``Flow`` records describing the two endpoints,
plus a ``direction`` ("out"/"in", who initiated the flow) and — when the backend
can attribute one — the owning ``process``/``pid``. conntrack tracks no
processes, so those flows are enriched by matching ``ss -p`` output.

The geo layer decides which side is the "remote" endpoint to trace.
"""
from __future__ import annotations

import ipaddress
import os
import re
import shutil
import subprocess
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class Flow:
    proto: str
    src: str
    sport: int
    dst: str
    dport: int
    state: str = ""
    # "out" (this host initiated) / "in" (a remote peer initiated) / ""
    direction: str = ""
    # Owning process, when the backend can attribute one (ss -p). conntrack
    # itself does not track processes; those flows are enriched from ss.
    process: str = ""
    pid: int = 0
    # Cumulative byte counters and smoothed RTT (ms) from ``ss -i``. Zero when
    # the backend cannot report them (conntrack, or UDP which has no info).
    tx: int = 0          # bytes sent by this host on the flow
    rx: int = 0          # bytes received by this host on the flow
    rtt: float = 0.0     # smoothed round-trip time, milliseconds

    def key(self) -> tuple:
        a = (self.src, self.sport)
        b = (self.dst, self.dport)
        if a > b:
            a, b = b, a
        return (self.proto, a, b)


def _strip_zone(ip: str) -> str:
    return ip.split("%", 1)[0]


# Linux default ephemeral range (net.ipv4.ip_local_port_range). A connection
# whose *local* port falls here is almost always client-initiated.
_EPHEMERAL_LO = 32768
_EPHEMERAL_HI = 60999


def _is_ephemeral(port: int) -> bool:
    return _EPHEMERAL_LO <= port <= _EPHEMERAL_HI


def _is_private(ip: str) -> bool:
    try:
        return ipaddress.ip_address(_strip_zone(ip)).is_private
    except ValueError:
        return False


def _direction(orig_src: str, orig_sport: int, orig_dst: str,
               orig_dport: int) -> str:
    """Infer flow direction from the ORIGINAL (initiator) tuple.

    conntrack records the initiating side first. If the initiator is on a
    private/local address and the peer is public, we started the connection
    ("out"); the reverse is a remote-initiated connection ("in"). When both
    sides look the same, fall back to the initiator's source port.
    """
    sp, dp = _is_private(orig_src), _is_private(orig_dst)
    if sp and not dp:
        return "out"
    if dp and not sp:
        return "in"
    return "out" if _is_ephemeral(orig_sport) else "in"


def _parse_addr_port(tok: str) -> tuple[str, int]:
    """Parse 'host:port' or '[host]:port'."""
    if tok.startswith("["):
        host, _, rest = tok[1:].partition("]")
        port = int(rest.lstrip(":"))
        return host, port
    # rsplit for IPv6 without brackets (rare in ss output) -- but ss brackets v6
    host, _, port = tok.rpartition(":")
    return host, int(port)


def _from_conntrack_line(line: str) -> Flow | None:
    parts = line.split()
    if not parts:
        return None
    proto = parts[0]
    if proto.startswith("ipv"):
        proto = parts[2] if len(parts) > 2 else parts[0]
    # find first src=/dst=/sport=/dport=
    src = dst = sport = dport = None
    state = ""
    for p in parts:
        if p.startswith("src=") and src is None:
            src = p[4:]
        elif p.startswith("dst=") and dst is None:
            dst = p[4:]
        elif p.startswith("sport=") and sport is None:
            try:
                sport = int(p[6:])
            except ValueError:
                pass
        elif p.startswith("dport=") and dport is None:
            try:
                dport = int(p[6:])
            except ValueError:
                pass
        elif p in ("ESTABLISHED", "TIME_WAIT", "CLOSE", "SYN_SENT",
                   "SYN_RECV", "FIN_WAIT", "LAST_ACK", "LISTEN", "UNREPLIED",
                   "ASSURED"):
            state = p
    if not src or not dst:
        return None
    src, dst = _strip_zone(src), _strip_zone(dst)
    sport, dport = sport or 0, dport or 0
    # The first src/dst/sport/dport seen are the ORIGINAL direction (the
    # initiator), so they tell us who started the flow.
    direction = _direction(src, sport, dst, dport)
    return Flow(proto, src, sport, dst, dport, state, direction)


def _conntrack_cmd() -> list[Flow]:
    if not shutil.which("conntrack"):
        return []
    try:
        out = subprocess.run(
            ["conntrack", "-L"], capture_output=True, text=True, timeout=3)
    except Exception:
        return []
    if out.returncode != 0:
        return []
    flows = []
    for line in out.stdout.splitlines():
        if line.startswith("con"):
            continue  # header "conntrack v..."
        f = _from_conntrack_line(line)
        if f:
            flows.append(f)
    return flows


def _conntrack_proc() -> list[Flow]:
    try:
        with open("/proc/net/nf_conntrack") as fh:
            data = fh.read()
    except PermissionError:
        return []
    except Exception:
        return []
    flows = []
    for line in data.splitlines():
        f = _from_conntrack_line(line)
        if f:
            flows.append(f)
    return flows


# users:(("chrome",pid=1234,fd=56),("chrome",pid=1235,fd=56))
_PROCESS_RE = re.compile(r'\("([^"]+)",pid=(\d+)')


def _parse_ss_process(line: str) -> tuple[str, int]:
    """Extract the first owning process name/pid from an ss -p line."""
    m = _PROCESS_RE.search(line)
    if not m:
        return "", 0
    return m.group(1), int(m.group(2))


_BYTES_RE = re.compile(r"\b(bytes_sent|bytes_received):(\d+)")
_RTT_RE = re.compile(r"\brtt:([\d.]+)(?:/([\d.]+))?")


def _parse_ss_stats(line: str) -> tuple[int, int, float]:
    """Parse the ``ss -i`` info line into (tx, rx, rtt_ms).

    ``bytes_sent`` is what this host sent, ``bytes_received`` what it got, and
    ``rtt:x/y`` is the smoothed round-trip time in ms (x = smoothed, y = last).
    Missing values stay zero.
    """
    tx = rx = 0
    for name, val in _BYTES_RE.findall(line):
        if name == "bytes_sent":
            tx = int(val)
        else:
            rx = int(val)
    rtt = 0.0
    m = _RTT_RE.search(line)
    if m:
        try:
            rtt = float(m.group(1))
        except ValueError:
            rtt = 0.0
    return tx, rx, rtt


def _ss() -> list[Flow]:
    if not shutil.which("ss"):
        return []
    # -p: owning process (own sockets only, unprivileged); -i: socket stats
    # (bytes, rtt); -H: no header.
    try:
        out = subprocess.run(
            ["ss", "-tunpHiH"], capture_output=True, text=True, timeout=3)
    except Exception:
        return []
    if out.returncode != 0:
        # Older/limited ss without -p: fall back to plain output.
        try:
            out = subprocess.run(
                ["ss", "-tunH"], capture_output=True, text=True, timeout=3)
        except Exception:
            return []
        if out.returncode != 0:
            return []
    flows = []
    # With -i, each socket is a data line optionally followed by a stats line
    # that begins with a tab. Buffer pending stats and attach them to the socket.
    pending = None
    for raw in out.stdout.splitlines():
        if raw.startswith("\t") or raw.startswith(" "):
            if pending is not None:
                tx, rx, rtt = _parse_ss_stats(raw)
                pending = replace(pending, tx=tx, rx=rx, rtt=rtt)
                flows.append(pending)
                pending = None
            continue
        if pending is not None:
            flows.append(pending)
            pending = None
        line = raw
        parts = line.split()
        if len(parts) < 5:
            continue
        proto = parts[0]
        state = parts[1]
        process, pid = _parse_ss_process(line)
        # local addr is parts[-2], peer is parts[-1] in typical ss -tunH output
        local_tok = None
        peer_tok = None
        # find the two address tokens (contain ':' and a digit port)
        addr_toks = [p for p in parts if ":" in p and p[-1].isdigit()]
        if len(addr_toks) >= 2:
            local_tok = addr_toks[0]
            peer_tok = addr_toks[1]
        elif len(addr_toks) == 1:
            local_tok = addr_toks[0]
        if not local_tok:
            continue
        try:
            src, sport = _parse_addr_port(local_tok)
        except Exception:
            continue
        dst, dport = "", 0
        if peer_tok:
            try:
                dst, dport = _parse_addr_port(peer_tok)
            except Exception:
                pass
        if not dst:
            continue
        src = _strip_zone(src)
        # ss lists the local socket first, so direction follows the local
        # ephemeral port (a listening/well-known local port means inbound).
        direction = "out" if _is_ephemeral(sport) else "in"
        # Hold the flow until its stats line (if any) arrives.
        pending = Flow(proto, src, sport, _strip_zone(dst), dport, state,
                       direction, process, pid)
        if proto != "tcp":
            flows.append(pending)
            pending = None
    if pending is not None:
        flows.append(pending)
    return flows


_BACKENDS = [
    ("conntrack -L", _conntrack_cmd),
    ("/proc/net/nf_conntrack", _conntrack_proc),
    ("ss -tunpH", _ss),
]


def available_backend() -> str | None:
    """Return the name of the first backend that yields data, or None."""
    for name, fn in _BACKENDS:
        if fn():
            return name
    return None


def _enrich_from_ss(flows: list[Flow]) -> list[Flow]:
    """Fill in process and per-socket stats on flows that lack them.

    conntrack sees every flow on the host but tracks no processes and no byte
    counters; ``ss -p -i`` knows both for our own sockets. Match the two by the
    canonical endpoint key and copy the attribution across.
    """
    need = [f for f in flows if not f.process or f.tx == 0]
    if not flows or not need:
        return flows
    info = {f.key(): f for f in _ss()}
    if not info:
        return flows
    out = []
    for f in flows:
        src = info.get(f.key())
        if src is None:
            out.append(f)
            continue
        out.append(replace(
            f,
            process=f.process or src.process,
            pid=f.pid or src.pid,
            tx=src.tx, rx=src.rx, rtt=src.rtt,
        ))
    return out


def poll() -> tuple[list[Flow], str]:
    """Return (deduped flows, backend_name_used)."""
    for name, fn in _BACKENDS:
        flows = fn()
        if flows:
            seen = {}
            for f in flows:
                seen[f.key()] = f
            deduped = list(seen.values())
            if name != "ss -tunH":
                deduped = _enrich_from_ss(deduped)
            return deduped, name
    return [], "none"


if __name__ == "__main__":
    flows, backend = poll()
    print(f"backend: {backend}  flows: {len(flows)}")
    for f in flows[:20]:
        print(f"  {f.proto:4} {f.src}:{f.sport} -> {f.dst}:{f.dport}  [{f.state}]")