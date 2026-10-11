"""GeoIP resolution for earthnet.

Two backends, both pure stdlib:

1. A self-contained MaxMind DB (MMDB) reader. Point it at a GeoLite2-City
   ``.mmdb`` (or any city-level MMDB) via ``--mmdb`` and it works fully offline.
2. An ip-api.com batch fallback (no key, HTTP, ~45 req/min) used when no MMDB is
   configured or an IP isn't in the database.

Lookups are cached to ``~/.cache/earthnet/geo.json`` so restarts are instant
and we stay well under the ip-api rate limit.
"""
from __future__ import annotations

import ipaddress
import json
import os
import struct
import threading
import urllib.request
from pathlib import Path

CACHE_DIR = Path(os.environ.get(
    "XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "earthnet"
GEO_CACHE = CACHE_DIR / "geo.json"

_MMDB_MARKER = b"\xab\xcd\xefMaxMind.com"


# ---------------------------------------------------------------------------
# Minimal MMDB reader
# ---------------------------------------------------------------------------

class _MMDB:
    """Just enough of the MaxMind DB format to read city lat/lon."""

    def __init__(self, path: str):
        with open(path, "rb") as f:
            self.buf = f.read()
        self.size = len(self.buf)
        meta_start = self.buf.rfind(_MMDB_MARKER, max(0, self.size - 128 * 1024))
        if meta_start < 0:
            raise ValueError("not an MMDB file (no metadata marker)")
        meta_start += len(_MMDB_MARKER)
        self.meta = self._decode(meta_start, meta_start)[0]
        self.node_count = int(self.meta["node_count"])
        self.record_size = int(self.meta["record_size"])
        self.ip_version = int(self.meta.get("ip_version", 4))
        self.node_byte_size = self.record_size * 2 // 8
        self.search_tree_size = self.node_count * self.node_byte_size
        self.data_start = self.search_tree_size + 16
        # IPv4 subtree start for IPv6 databases (walk 96 zero bits)
        self.ipv4_start = 0
        if self.ip_version == 6:
            node = 0
            for _ in range(96):
                if node >= self.node_count:
                    break
                node = self._read_node(node, 0)
            self.ipv4_start = node

    # -- search tree --
    def _read_node(self, node: int, index: int) -> int:
        base = node * self.node_byte_size
        b = self.buf
        rs = self.record_size
        if rs == 24:
            off = base + index * 3
            return (b[off] << 16) | (b[off + 1] << 8) | b[off + 2]
        if rs == 28:
            off = base + 3 * index
            if index == 0:
                mid = (b[off + 3] >> 4) & 0x0F
                return (mid << 24) | (b[off] << 16) | (b[off + 1] << 8) | b[off + 2]
            else:
                mid = b[off] & 0x0F
                return (mid << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3]
        if rs == 32:
            off = base + index * 4
            return struct.unpack_from("!I", b, off)[0]
        raise ValueError(f"unsupported record size {rs}")

    def lookup(self, ip: str):
        addr = ipaddress.ip_address(ip)
        packed = addr.packed
        bit_count = len(packed) * 8
        if self.ip_version == 6 and bit_count == 32:
            node = self.ipv4_start
        else:
            node = 0
        i = 0
        while i < bit_count and node < self.node_count:
            bit = (packed[i >> 3] >> (7 - (i & 7))) & 1
            node = self._read_node(node, bit)
            i += 1
        if node == self.node_count:
            return None
        if node > self.node_count:
            resolved = node - self.node_count + self.search_tree_size
            return self._decode(resolved, self.data_start)[0]
        return None

    # -- data section decoder --
    def _decode(self, offset: int, pointer_base: int):
        b = self.buf
        ctrl = b[offset]
        new_off = offset + 1
        type_num = ctrl >> 5
        if type_num == 0:
            type_num = b[new_off] + 7
            new_off += 1
        size, new_off = self._size(ctrl, new_off, type_num)
        return self._decode_value(type_num, size, new_off, pointer_base)

    def _size(self, ctrl, offset, type_num):
        size = ctrl & 0x1F
        if type_num == 1 or size < 29:
            return size, offset
        b = self.buf
        if size == 29:
            return 29 + b[offset], offset + 1
        if size == 30:
            return 285 + struct.unpack_from("!H", b, offset)[0], offset + 2
        return 65821 + ((b[offset] << 16) | (b[offset + 1] << 8) | b[offset + 2]), offset + 3

    def _decode_value(self, type_num, size, offset, pointer_base):
        b = self.buf
        if type_num == 1:  # pointer
            psize = (size >> 3) + 1
            vvv = size & 0x07
            if psize == 1:
                ptr = (vvv << 8) | b[offset]
                new_off = offset + 1
            elif psize == 2:
                ptr = (vvv << 16) | (b[offset] << 8) | b[offset + 1]
                ptr += 2048
                new_off = offset + 2
            elif psize == 3:
                ptr = (vvv << 24) | (b[offset] << 16) | (b[offset + 1] << 8) | b[offset + 2]
                ptr += 526336
                new_off = offset + 3
            else:
                ptr = struct.unpack_from("!I", b, offset)[0]
                new_off = offset + 4
            val = self._decode(pointer_base + ptr, pointer_base)[0]
            return val, new_off
        if type_num == 2:  # utf8
            return b[offset:offset + size].decode("utf-8", "replace"), offset + size
        if type_num == 3:  # double
            return struct.unpack_from("!d", b, offset)[0], offset + 8
        if type_num == 4:  # bytes
            return b[offset:offset + size], offset + size
        if type_num in (5, 6, 9, 10):  # uint16/32/64/128
            return int.from_bytes(b[offset:offset + size], "big"), offset + size
        if type_num == 7:  # map
            out = {}
            off = offset
            for _ in range(size):
                k, off = self._decode(off, pointer_base)
                v, off = self._decode(off, pointer_base)
                out[k] = v
            return out, off
        if type_num == 8:  # int32
            raw = b[offset:offset + size]
            if size and size != 4:
                raw = raw.rjust(4, b"\x00")
            return struct.unpack("!i", raw)[0] if size else 0, offset + size
        if type_num == 11:  # array
            out = []
            off = offset
            for _ in range(size):
                v, off = self._decode(off, pointer_base)
                out.append(v)
            return out, off
        if type_num == 14:  # boolean
            return size != 0, offset
        if type_num == 15:  # float
            return struct.unpack_from("!f", b, offset)[0], offset + 4
        # 12 (data cache) / 13 (end marker) deprecated -> skip
        return None, offset + size


# ---------------------------------------------------------------------------
# Resolver
# ---------------------------------------------------------------------------

def _is_private(ip: str) -> bool:
    try:
        return ipaddress.ip_address(ip).is_private
    except ValueError:
        return True


def remote_endpoint(src: str, dst: str):
    """Pick the 'foreign' side of a connection for tracing. Returns the public
    IP, or None if both sides are local."""
    sp, dp = _is_private(src), _is_private(dst)
    if sp and not dp:
        return dst
    if dp and not sp:
        return src
    if not sp and not dp:
        # both public: prefer the smaller numeric as "remote" (arbitrary but
        # stable); the home side is supplied separately by the capture layer
        return dst if dst > src else src
    return None


class GeoResolver:
    def __init__(self, mmdb_path: str | None = None):
        self.mmdb: _MMDB | None = None
        if mmdb_path and os.path.exists(mmdb_path):
            try:
                self.mmdb = _MMDB(mmdb_path)
                print(f"[geo] loaded MMDB: {mmdb_path} "
                      f"(ip_version={self.mmdb.ip_version}, "
                      f"nodes={self.mmdb.node_count})", flush=True)
            except Exception as e:
                print(f"[geo] MMDB load failed, using ip-api fallback: {e}",
                      flush=True)
        else:
            print("[geo] no MMDB configured; using ip-api.com fallback "
                  "(free tier, ~45 req/min)", flush=True)
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        self.cache: dict[str, dict] = {}
        try:
            self.cache = json.loads(GEO_CACHE.read_text())
        except Exception:
            self.cache = {}
        self._lock = threading.Lock()
        self._dirty = False
        self.home: tuple[float, float] | None = None

    def save(self):
        if not self._dirty:
            return
        try:
            GEO_CACHE.write_text(json.dumps(self.cache))
            self._dirty = False
        except Exception:
            pass

    def _mmdb_lookup(self, ip: str) -> dict | None:
        if not self.mmdb:
            return None
        try:
            rec = self.mmdb.lookup(ip)
        except Exception:
            return None
        if not isinstance(rec, dict):
            return None
        loc = rec.get("location")
        if not isinstance(loc, dict) or "latitude" not in loc:
            return None
        country = rec.get("country", {}) or {}
        city = rec.get("city", {}) or {}
        traits = rec.get("traits", {}) or {}
        names = lambda d: d.get("names", {}) or {}
        # GeoLite2-City carries ASN in traits; GeoLite2-ASN has it top-level.
        asn = traits.get("autonomous_system_number") or rec.get("autonomous_system_number") or 0
        org = (traits.get("autonomous_system_organization")
               or rec.get("autonomous_system_organization") or "")
        return {
            "lat": float(loc["latitude"]),
            "lon": float(loc["longitude"]),
            "city": names(city).get("en", ""),
            "country": names(country).get("en", ""),
            "cc": country.get("iso_code", ""),
            "isp": org,
            "org": org,
            "as": ("AS%d %s" % (asn, org)).strip() if asn else org,
            "src": "mmdb",
        }

    def _ipapi_batch(self, ips: list[str]) -> dict[str, dict]:
        if not ips:
            return {}
        body = json.dumps(ips).encode()
        url = ("http://ip-api.com/batch"
               "?fields=status,query,country,countryCode,city,lat,lon,"
               "isp,org,as&lang=en")
        try:
            req = urllib.request.Request(
                url, data=body,
                headers={"User-Agent": "earthnet/1.0",
                         "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=8) as r:
                rows = json.loads(r.read())
        except Exception as e:
            print(f"[geo] ip-api batch failed ({len(ips)} ips): {e}", flush=True)
            return {}
        out = {}
        for row in rows:
            if row.get("status") != "success":
                continue
            out[row["query"]] = {
                "lat": float(row.get("lat") or 0),
                "lon": float(row.get("lon") or 0),
                "city": row.get("city") or "",
                "country": row.get("country") or "",
                "cc": (row.get("countryCode") or "").upper(),
                "isp": row.get("isp") or "",
                "org": row.get("org") or "",
                "as": row.get("as") or "",
                "src": "ipapi",
            }
        return out

    def resolve_many(self, ips: list[str]) -> dict[str, dict]:
        """Resolve a batch, using cache + MMDB first, ip-api for the rest."""
        result: dict[str, dict] = {}
        todo = []
        with self._lock:
            for ip in ips:
                c = self.cache.get(ip)
                # Entries written before ISP/ASN was added lack these keys;
                # refresh them once so the legend isn't stuck on blanks.
                if c and "isp" in c:
                    result[ip] = c
                elif self.mmdb:
                    m = self._mmdb_lookup(ip)
                    if m:
                        self.cache[ip] = m
                        result[ip] = m
                        self._dirty = True
                    else:
                        todo.append(ip)
                else:
                    todo.append(ip)
        # ip-api in chunks of 100
        for i in range(0, len(todo), 100):
            chunk = todo[i:i + 100]
            got = self._ipapi_batch(chunk)
            with self._lock:
                for ip in chunk:
                    g = got.get(ip)
                    if g:
                        self.cache[ip] = g
                        result[ip] = g
                        self._dirty = True
        self.save()
        return result

    def resolve(self, ip: str) -> dict | None:
        return self.resolve_many([ip]).get(ip)

    def detect_home(self) -> tuple[float, float] | None:
        """Geolocate this machine's public IP."""
        if self.home:
            return self.home
        try:
            req = urllib.request.Request(
                "http://ip-api.com/json/?fields=query,lat,lon",
                headers={"User-Agent": "earthnet/1.0"})
            with urllib.request.urlopen(req, timeout=8) as r:
                d = json.loads(r.read())
            if d.get("lat") is not None:
                self.home = (float(d["lat"]), float(d["lon"]))
                print(f"[geo] home location: {self.home} (public ip {d.get('query')})",
                      flush=True)
        except Exception as e:
            print(f"[geo] home detection failed: {e}", flush=True)
        return self.home


if __name__ == "__main__":
    import sys
    g = GeoResolver(sys.argv[1] if len(sys.argv) > 1 else None)
    g.detect_home()
    for ip in sys.argv[2:]:
        print(ip, "->", g.resolve(ip))