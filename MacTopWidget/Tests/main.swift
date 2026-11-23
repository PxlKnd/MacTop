// CPU-Sampler-Validierung: 5 Ticks à 1 s gegen top vergleichen
import Foundation

let c = CPUSampler()
_ = c.sample()  // Erstsample etabliert prev
for i in 1...5 {
    Thread.sleep(forTimeInterval: 1.0)
    let s = c.sample()
    let cores = s.perCore.map { String(format: "%.0f", $0) }.joined(separator: ",")
    print("tick\(i) total=\(String(format: "%.1f", s.total))% cores=[\(cores)]")
}
