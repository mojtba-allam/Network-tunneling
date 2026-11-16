#!/usr/bin/env python3
"""Alternate-path probe: DNS split, mtr, openssl, curl timings, route get.
Writes NDJSON debug logs. Does not change routing."""
from __future__ import annotations

import json
import socket
import ssl
import subprocess
import time
from pathlib import Path

SESSION = "f346c5"
LOG_PATH = Path("/home/panda/Desktop/Network-tunneling/.cursor/debug-f346c5.log")
RUN_ID = "alt-tools-timeout"


def dbg(hypothesis_id: str, location: str, message: str, data: dict) -> None:
    # #region agent log
    rec = {
        "sessionId": SESSION,
        "runId": RUN_ID,
        "hypothesisId": hypothesis_id,
        "location": location,
        "message": message,
        "data": data,
        "timestamp": int(time.time() * 1000),
        "id": f"log_{int(time.time()*1000)}_{hypothesis_id}",
    }
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")
    # #endregion
    print(f"[{hypothesis_id}] {message} {json.dumps(data)[:500]}")


def run(cmd: list[str], timeout: int = 25) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = (p.stdout or "") + (p.stderr or "")
        return p.returncode, out.strip()
    except Exception as e:
        return 99, f"{type(e).__name__}: {e}"


def dns_query(name: str, server: str) -> dict:
    code, out = run(["dig", f"@{server}", "+time=2", "+tries=1", "+short", name, "A"], timeout=8)
    ips = [ln.strip() for ln in out.splitlines() if ln.strip() and not ln.startswith(";")]
    return {"server": server, "rc": code, "ips": ips, "raw": out[:400]}


def route_get(ip: str) -> str:
    code, out = run(["ip", "route", "get", ip], timeout=5)
    return out.splitlines()[0] if out else f"rc={code}"


def tcp_connect(ip: str, port: int, timeout: float = 2.5, iface: str | None = None) -> dict:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    t0 = time.time()
    try:
        if iface:
            s.setsockopt(socket.SOL_SOCKET, 25, iface.encode() + b"\0")
        s.connect((ip, port))
        local = s.getsockname()
        return {"ok": True, "sec": round(time.time() - t0, 3), "local": list(local), "iface": iface, "port": port}
    except Exception as e:
        return {
            "ok": False,
            "sec": round(time.time() - t0, 3),
            "error": f"{type(e).__name__}: {e}",
            "iface": iface,
            "port": port,
        }
    finally:
        try:
            s.close()
        except Exception:
            pass


def openssl_sni(host: str, ip: str, timeout: int = 4) -> dict:
    code, out = run(
        ["timeout", str(timeout), "openssl", "s_client", "-connect", f"{ip}:443", "-servername", host, "-brief"],
        timeout=timeout + 2,
    )
    lines = [ln for ln in out.splitlines() if ln][:12]
    return {"rc": code, "lines": lines}


def curl_timings(url: str, resolve: str | None = None, iface: str | None = None) -> dict:
    cmd = [
        "curl",
        "-sS",
        "-o",
        "/dev/null",
        "-w",
        "%{http_code} %{remote_ip} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_total}",
        "--max-time",
        "5",
        "--connect-timeout",
        "3",
    ]
    if resolve:
        cmd.extend(["--resolve", resolve])
    if iface:
        cmd.extend(["--interface", iface])
    cmd.append(url)
    code, out = run(cmd, timeout=7)
    return {"rc": code, "out": out, "iface": iface, "resolve": resolve}


def mtr_report(ip: str, iface: str | None = None) -> dict:
    cmd = ["mtr", "-n", "-r", "-c", "1", "-w", "--max-ttl", "8", ip]
    if iface:
        cmd.extend(["-I", iface])
    code, out = run(cmd, timeout=12)
    hops = out.splitlines()[-8:]
    return {"rc": code, "iface": iface, "tail": hops}


def main() -> None:
    hosts = {
        "youtube": "www.youtube.com",
        "golestan": "golestan.ikiu.ac.ir",
    }
    dns_servers = ["127.0.0.53", "8.8.8.8", "5.202.100.100"]

    for key, host in hosts.items():
        answers = {s: dns_query(host, s) for s in dns_servers}
        dbg(
            "D",
            "debug_golestan_probe.py:dns",
            f"dns answers for {host}",
            {"host": host, "key": key, "answers": answers},
        )

    gol_ip = dns_query("golestan.ikiu.ac.ir", "127.0.0.53")["ips"]
    yt_ip = dns_query("www.youtube.com", "127.0.0.53")["ips"]
    gol = gol_ip[0] if gol_ip else "185.114.188.24"
    yt = yt_ip[0] if yt_ip else "142.251.154.4"

    for name, ip in (("golestan", gol), ("youtube", yt)):
        r = route_get(ip)
        dbg(
            "A",
            "debug_golestan_probe.py:route",
            "ip route get",
            {"name": name, "ip": ip, "route": r, "via_vpn": "vpn0" in r, "via_wifi": "wlp0s20f3" in r},
        )

    for spec in (
        (gol, "golestan", 443, None),
        (gol, "golestan", 443, "vpn0"),
        (gol, "golestan", 443, "wlp0s20f3"),
        (gol, "golestan", 80, None),
        (yt, "youtube", 443, None),
    ):
        ip, name, port, iface = spec
        res = tcp_connect(ip, port, iface=iface)
        dbg("C", "debug_golestan_probe.py:tcp", "tcp connect", {"name": name, "ip": ip, **res})

    dbg("E", "debug_golestan_probe.py:openssl-golestan", "openssl s_client golestan", openssl_sni("golestan.ikiu.ac.ir", gol))
    dbg("E", "debug_golestan_probe.py:openssl-youtube", "openssl s_client youtube", openssl_sni("www.youtube.com", yt))

    dbg(
        "E",
        "debug_golestan_probe.py:curl-golestan-vpn",
        "curl golestan via vpn0 + resolve",
        curl_timings("https://golestan.ikiu.ac.ir/", f"golestan.ikiu.ac.ir:443:{gol}", "vpn0"),
    )
    dbg(
        "A",
        "debug_golestan_probe.py:curl-golestan-wifi",
        "curl golestan via wifi + resolve",
        curl_timings("https://golestan.ikiu.ac.ir/", f"golestan.ikiu.ac.ir:443:{gol}", "wlp0s20f3"),
    )
    dbg(
        "E",
        "debug_golestan_probe.py:curl-youtube-vpn",
        "curl youtube via vpn0",
        curl_timings("https://www.youtube.com/", f"www.youtube.com:443:{yt}", "vpn0"),
    )

    dbg("B", "debug_golestan_probe.py:mtr-gol-default", "mtr golestan default", mtr_report(gol))
    dbg("B", "debug_golestan_probe.py:mtr-yt-vpn", "mtr youtube vpn0", mtr_report(yt, "vpn0"))

    print("done; logs ->", LOG_PATH)


if __name__ == "__main__":
    main()
