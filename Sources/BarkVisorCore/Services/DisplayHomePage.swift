import Foundation

public enum DisplayHomePage {
    public static let width = 800
    public static let height = 480

    public static func html(
        report: HomeDeviceHealthReport,
        now: Date = Date(),
        timeZone: TimeZone = .current,
    ) -> String {
        let clock = clockString(now, timeZone: timeZone)
        let cards = report.devices.map(cardHTML).joined()
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=\(width), height=\(height)">
        <title>Home</title>
        <style>
        html,body{margin:0;padding:0;background:#fff;color:#000;}
        *{box-sizing:border-box;}
        .board{width:\(width)px;height:\(height)px;padding:12px 14px 10px;display:flex;flex-direction:column;gap:8px;font-family:ui-monospace,Menlo,Consolas,monospace;background:#fff;color:#000;overflow:hidden;}
        .head,.foot{display:flex;justify-content:space-between;align-items:baseline;font-weight:600;letter-spacing:.04em;text-transform:uppercase;}
        .head{font-size:18px;height:28px;border-bottom:3px solid #000;padding-bottom:6px;}
        .head .meta{font-size:14px;font-weight:500;}
        .foot{font-size:11px;height:20px;border-top:2px solid #000;padding-top:6px;letter-spacing:.08em;}
        .quad{flex:1;display:grid;grid-template-columns:1fr 1fr;grid-template-rows:1fr 1fr;gap:8px;min-height:0;}
        .card{border:3px solid #000;padding:10px 12px 8px;display:flex;flex-direction:column;min-width:0;min-height:0;}
        .card.down{background:#000;color:#fff;}
        .name{font-size:22px;font-weight:700;line-height:1;}
        .plat{font-size:11px;margin:4px 0 8px;letter-spacing:.04em;text-transform:uppercase;}
        .row{display:flex;align-items:center;gap:8px;font-size:13px;font-weight:600;margin-top:4px;}
        .row .k{width:36px;flex:none;}
        .bar{flex:1;height:10px;border:2px solid currentColor;position:relative;}
        .bar i{display:block;height:100%;background:currentColor;}
        .row .v{width:48px;text-align:right;flex:none;}
        .temps,.loads{font-size:13px;font-weight:600;margin-top:auto;padding-top:6px;}
        .stamp{font-size:20px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;margin-top:auto;}
        </style>
        </head>
        <body>
        <div class="board">
        <header class="head"><span>Home</span><span class="meta">\(report.totals.reachable)/\(report.totals.devices) up · \(escape(clock))</span></header>
        <div class="quad">\(cards)</div>
        <footer class="foot"><span>Fetched \(escape(clock))</span><span>BarkVisor</span></footer>
        </div>
        </body>
        </html>
        """
    }

    static func cardHTML(_ device: HomeDeviceHealthSnapshot) -> String {
        let name = escape(device.label)
        let plat = escape(platformLine(device))
        if device.reachability != HomeDeviceHealthAggregator.ok {
            return """
            <article class="card down"><div class="name">\(name)</div><div class="plat">\(plat)</div><div class="stamp">Unreachable</div></article>
            """
        }
        let res = device.resources
        let cpuBar = bar("CPU", res?.cpuLoadPercent)
        let gpuBar = bar("GPU", res?.gpuPercent)
        let memPct: Double? = {
            guard let used = res?.memoryUsedMB, let total = res?.memoryTotalMB, total > 0 else { return nil }
            return min((Double(used) / Double(total)) * 100, 100)
        }()
        let memBar = bar("MEM", memPct)
        let temps = [sensorLine(res), memLine(res)].filter { !$0.isEmpty }.joined(separator: " · ")
        let loads = loadLine(device)
        return """
        <article class="card"><div class="name">\(name)</div><div class="plat">\(plat)</div>\(cpuBar)\(gpuBar)\(memBar)<div class="temps">\(escape(temps))</div><div class="loads">\(escape(loads))</div></article>
        """
    }

    static func bar(_ label: String, _ value: Double?) -> String {
        guard let value else { return "" }
        let w = max(0, min(100, Int(value.rounded())))
        return """
        <div class="row"><span class="k">\(label)</span><span class="bar"><i style="width:\(w)%"></i></span><span class="v">\(w)%</span></div>
        """
    }

    static func platformLine(_ device: HomeDeviceHealthSnapshot) -> String {
        let os = device.platform?.os ?? ""
        let arch = device.platform?.arch ?? ""
        if !os.isEmpty, !arch.isEmpty { return "\(os) · \(arch)" }
        return os.isEmpty ? arch : os
    }

    static func sensorLine(_ res: HomeDeviceResourceSummary?) -> String {
        var bits: [String] = []
        if let c = res?.cpuTemperatureC { bits.append("CPU \(Int(c.rounded()))°C") }
        if let g = res?.gpuTemperatureC { bits.append("GPU \(Int(g.rounded()))°C") }
        if let d = res?.diskTemperatureC { bits.append("Disk \(Int(d.rounded()))°C") }
        if bits.isEmpty, let t = res?.temperatureC { bits.append("\(Int(t.rounded()))°C") }
        return bits.joined(separator: " · ")
    }

    static func memLine(_ res: HomeDeviceResourceSummary?) -> String {
        guard let used = res?.memoryUsedMB, let total = res?.memoryTotalMB else { return "" }
        let usedGB = Double(used) / 1024
        let totalGB = Double(total) / 1024
        let usedText = used % 1024 == 0 ? String(Int(usedGB)) : String(format: "%.1f", usedGB)
        let totalText = total % 1024 == 0 ? String(Int(totalGB)) : String(format: "%.0f", totalGB)
        return "\(usedText) / \(totalText) GB"
    }

    static func loadLine(_ device: HomeDeviceHealthSnapshot) -> String {
        var bits: [String] = []
        if let count = device.workloadCount {
            bits.append(count == 1 ? "1 workload" : "\(count) workloads")
        }
        if let failed = device.healthCounts?["failed"], failed > 0 {
            bits.append("\(failed) failed")
        }
        return bits.joined(separator: " · ")
    }

    static func clockString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func escape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
