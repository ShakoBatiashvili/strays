import StraysSystem
import Foundation
let t0 = Date()
let recs = ProcessReader.snapshot()
let dt = Date().timeIntervalSince(t0)
for r in recs where !r.listening.isEmpty { print(r.pid, r.name, r.listening.map { "\($0.address):\($0.port)" }) }
let me = recs.filter { $0.uid == getuid() }
print("total", recs.count, "mine", me.count, "ms", Int(dt*1000))
if let r = recs.first(where: { $0.pid == 45392 }) { print(r.arguments, r.cwd ?? "-", r.tty ?? "-", r.cpuSeconds, r.residentBytes) }
if let r = recs.first(where: { $0.pid == 63937 }) { print(r.arguments, r.tty ?? "-", r.startDate, r.cpuSeconds) }
