"""Local, read-only Windows measurements."""
import json
import platform
import socket
import subprocess
import time
from datetime import datetime

import psutil


def stamp(timestamp):
    return datetime.fromtimestamp(timestamp).astimezone().isoformat(timespec="seconds")


def snapshot():
    ram = psutil.virtual_memory()
    cores = psutil.cpu_percent(percpu=True)
    disks = []
    for part in psutil.disk_partitions():
        # Знімний носій може зникнути між переліком дисків і читанням розміру.
        try:
            usage = psutil.disk_usage(part.mountpoint)
        except OSError:
            continue
        disks.append(dict(path=part.mountpoint, fs=part.fstype, total=usage.total,
                          free=usage.free, percent=usage.percent))
    links = psutil.net_if_stats()
    addresses = [(name, address.address) for name, entries in psutil.net_if_addrs().items()
                 if name in links and links[name].isup for address in entries
                 if address.family == socket.AF_INET and not address.address.startswith("127.")]
    processes = []
    for proc in psutil.process_iter(["pid", "name", "memory_info", "create_time"]):
        data = proc.info
        processes.append(dict(pid=data["pid"], name=data["name"] or "—",
                              memory=data["memory_info"].rss if data["memory_info"] else None,
                              started=stamp(data["create_time"]) if data["create_time"] else None))
    processes.sort(key=lambda row: row["memory"] or 0, reverse=True)
    return dict(time=stamp(time.time()), host=socket.gethostname(), system=platform.platform(),
                boot=stamp(psutil.boot_time()), cpu=round(sum(cores)/max(len(cores), 1), 1),
                cores=cores, ram=ram.percent, ram_total=ram.total, ram_used=ram.total-ram.available,
                disks=disks, addresses=addresses, processes=processes)


def power_events():
    # Фільтруємо на стороні журналу. Один і той самий код у різних джерелах
    # може означати різне. Для 41 та 6008 час запису пізніший за сам збій.
    script = """
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $ErrorActionPreference='Stop'
    $q="*[System[(Provider[@Name='Microsoft-Windows-Kernel-General'] and (EventID=12 or EventID=13)) or (Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=41) or (Provider[@Name='EventLog'] and EventID=6008)]]"
    try {
      $rows=@(Get-WinEvent -LogName System -FilterXPath $q -MaxEvents 200 | ForEach-Object {
        @{id=$_.Id; time=$_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'); source=$_.ProviderName}
      })
      ConvertTo-Json -InputObject $rows -Compress
    } catch { if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {'[]'} else {throw} }
    """
    result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
                            capture_output=True, encoding="utf-8", errors="replace", timeout=25,
                            creationflags=subprocess.CREATE_NO_WINDOW, check=True)
    return json.loads(result.stdout.lstrip("\ufeff"))

