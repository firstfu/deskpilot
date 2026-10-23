//
//  Benchmark.swift
//  DeskPilot（iOS 用戶端）
//
//  一鍵量測：在真實 Wi-Fi 環境下量延遲與流量，結果顯示在手機上並回報給主機 log。
//  三個階段：
//  1. 靜止：什麼都不做 8 秒，量閒置流量（理想值 ≈ 0）
//  2. 延遲：送 40 個探針。主機收到探針 → 主機視窗重繪 → 擷取 → 編碼 → 傳回，
//     手機收到那張影格時計時。兩端時間都用手機時鐘，不需對時。
//     未含：手機解碼＋上螢幕（約 1 個 vsync）與觸控面板本身的延遲。
//  3. 捲動：連續送捲動事件 8 秒，量捲動時的影格率與流量（游標下需要有可捲動的內容）
//

import Foundation

extension ClientSession {
    /// 執行完整量測。量測期間請勿操作手機。
    func runBenchmark() async {
        guard let link, benchmarkStatus == nil else { return }
        benchmarkResult = nil

        // 1. 靜止
        benchmarkStatus = "1/3 靜止流量（8 秒，請勿操作）…"
        try? await Task.sleep(for: .seconds(1.5))
        var idleKbps: [Double] = []
        for _ in 0..<8 {
            try? await Task.sleep(for: .seconds(1))
            idleKbps.append(kbps)
        }

        // 2. 延遲
        benchmarkStatus = "2/3 延遲探針（40 次）…"
        probeSamples = []
        let base = UInt32.random(in: 1...1_000_000)
        for i in 0..<40 {
            link.sendProbe(base + UInt32(i))
            // 間隔要大於一次來回，避免探針互相重疊
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(1))
        let latency = probeSamples.sorted()

        // 3. 捲動
        benchmarkStatus = "3/3 捲動流量（8 秒）…"
        let sampler = Task { @MainActor [weak self] () -> ([Double], [Int]) in
            var k: [Double] = []
            var f: [Int] = []
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(1))
                k.append(self?.kbps ?? 0)
                f.append(self?.fps ?? 0)
            }
            return (k, f)
        }
        // 60Hz 送捲動，每秒換方向，內容來回捲不會捲到底
        for step in 0..<(8 * 60) {
            let dir: Int16 = (step / 60) % 2 == 0 ? -1 : 1
            send(.scroll(dx: 0, dy: 12 * dir))
            try? await Task.sleep(for: .milliseconds(16))
        }
        let (scrollKbps, scrollFps) = await sampler.value

        let report = Self.formatReport(idleKbps: idleKbps, latency: latency,
                                       scrollKbps: scrollKbps, scrollFps: scrollFps, rtt: rttMs)
        benchmarkResult = report
        benchmarkStatus = nil
        link.send(.report, Data(report.utf8))
    }

    private static func formatReport(idleKbps: [Double], latency: [Double],
                                     scrollKbps: [Double], scrollFps: [Int], rtt: Double?) -> String {
        func pct(_ a: [Double], _ p: Double) -> Double {
            guard !a.isEmpty else { return .nan }
            return a[min(a.count - 1, Int(Double(a.count - 1) * p))]
        }
        func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        let idle = avg(idleKbps)
        let scroll = avg(scrollKbps)
        let fps = scrollFps.isEmpty ? 0 : Double(scrollFps.reduce(0, +)) / Double(scrollFps.count)
        return """
        靜止：平均 \(String(format: "%.1f", idle)) kbps
        延遲（\(latency.count)/40）：中位 \(String(format: "%.1f", pct(latency, 0.5))) ms，P90 \(String(format: "%.1f", pct(latency, 0.9))) ms，最佳 \(String(format: "%.1f", latency.first ?? .nan)) ms
        捲動：平均 \(String(format: "%.0f", scroll)) kbps（\(String(format: "%.2f", scroll / 8 / 1000)) MB/s），\(String(format: "%.0f", fps)) fps
        網路 RTT：\(rtt.map { String(format: "%.1f ms", $0) } ?? "—")
        """
    }
}
