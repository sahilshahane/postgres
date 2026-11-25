#!/usr/bin/env python3
"""BenchBase helper for bench.sh and make_golden_std.sh.

  bbconf.py BB_HOME BENCH OUT.xml PORT TERMINALS SECONDS SCALE
      Write a run config from BenchBase's own sample_BENCH_config.xml for
      PostgreSQL, changing only: the URL (localhost:PORT, database postgres),
      user (current user, trust auth), scale factor, terminals, run time
      (rate unlimited, 3 s warmup); for ycsb the weights of YCSB workload A
      (50% ReadRecord, 50% UpdateRecord).  Everything else (isolation level,
      TPC-C transaction mix) stays as the sample has it.
  bbconf.py --parse OUTDIR
      Print "requests_per_s avg_latency_ms" from the run's summary.json.
"""
import getpass, glob, json, os, sys
import xml.etree.ElementTree as ET

if sys.argv[1] == "--parse":
    files = glob.glob(os.path.join(sys.argv[2], "*.summary.json"))
    if not files:
        print("0 0"); sys.exit(0)
    d = json.load(open(files[0]))
    tps = next(v for k, v in d.items() if k.startswith("Throughput"))
    lat = next(v for k, v in d["Latency Distribution"].items() if k.startswith("Average"))
    print(f"{float(tps):.2f} {float(lat) / 1000:.3f}")
    sys.exit(0)

home, bench, out, port, terms, secs, scale = sys.argv[1:8]
t = ET.parse(os.path.join(home, "config", "postgres", f"sample_{bench}_config.xml"))
r = t.getroot()
def set_(tag, val):
    e = r.find(tag)
    if e is None:
        e = ET.SubElement(r, tag)
    e.text = str(val)
set_("url", f"jdbc:postgresql://localhost:{port}/postgres?sslmode=disable"
            f"&ApplicationName={bench}&reWriteBatchedInserts=true")
set_("username", getpass.getuser()); set_("password", "")
set_("scalefactor", scale); set_("terminals", terms)
set_("loaderThreads", 8)
works = r.find("works")
for w in list(works):
    works.remove(w)
w = ET.SubElement(works, "work")
ET.SubElement(w, "warmup").text = "3"
ET.SubElement(w, "time").text = str(secs)
ET.SubElement(w, "rate").text = "unlimited"
names = [tt.findtext("name") for tt in r.find("transactiontypes")]
if bench == "ycsb":
    weights = [50 if n in ("ReadRecord", "UpdateRecord") else 0 for n in names]
else:
    old = [x for x in ET.parse(os.path.join(home, "config", "postgres",
           f"sample_{bench}_config.xml")).getroot().find("works/work").findtext("weights").split(",")]
    weights = old
ET.SubElement(w, "weights").text = ",".join(str(x).strip() for x in weights)
t.write(out)
