import socket
import unittest
from types import SimpleNamespace as Row
from unittest.mock import patch

import metrics


class Measurements(unittest.TestCase):
    @patch("metrics.psutil")
    def test_snapshot_filters_interfaces_and_handles_unavailable_devices(self, ps):
        ps.virtual_memory.return_value = Row(total=100, available=60, percent=40)
        ps.cpu_percent.return_value = [10, 30]
        ps.boot_time.return_value = 1_700_000_000
        ps.disk_partitions.return_value = [Row(mountpoint=p, fstype="NTFS") for p in ("C:/", "D:/")]
        ps.disk_usage.side_effect = [Row(total=100, free=30, percent=70), OSError()]
        ps.net_if_stats.return_value = {"demo": Row(isup=True), "offline": Row(isup=False)}
        ps.net_if_addrs.return_value = {
            "demo": [Row(family=socket.AF_INET, address=a) for a in ("127.0.0.1", "192.0.2.1")],
            "offline": [Row(family=socket.AF_INET, address="192.0.2.2")],
        }
        ps.process_iter.return_value = [
            Row(info=dict(pid=1, name=None, memory_info=None, create_time=None)),
            Row(info=dict(pid=2, name="Demo", memory_info=Row(rss=1024), create_time=1_700_001_000)),
        ]
        result = metrics.snapshot()
        self.assertEqual(result["cpu"], 20)
        self.assertEqual(result["ram_used"], 40)
        self.assertEqual([d["path"] for d in result["disks"]], ["C:/"])
        self.assertEqual(result["addresses"], [("demo", "192.0.2.1")])
        self.assertEqual([p["pid"] for p in result["processes"]], [2, 1])
        self.assertIsNone(result["processes"][1]["started"])

    @patch("metrics.subprocess.run")
    def test_events_accept_empty_log_and_utf8_bom(self, run):
        for payload, expected in [("[]", []), ('\ufeff[{"id":12}]', [{"id": 12}])]:
            with self.subTest(payload=payload):
                run.return_value.stdout = payload
                self.assertEqual(metrics.power_events(), expected)
