import AppKit

MainActor.assumeIsolated {
    // Developer check of Cohere Transcribe alone (no keyboard monitoring), downloading the model if needed:
    // --cohere-check <audio> <language> <out.txt>.
    if let index = CommandLine.arguments.firstIndex(of: "--cohere-check"), index + 3 < CommandLine.arguments.count {
        let arguments = CommandLine.arguments
        let engine = CohereEngine()
        Task { @MainActor in
            var report = ""
            do {
                var started = Date()
                _ = try await engine.prepare().value
                report += String(format: "load %.2f s\n", Date().timeIntervalSince(started))
                for _ in 0..<2 {
                    started = Date()
                    let text = try await engine.transcribe(file: URL(fileURLWithPath: arguments[index + 1]), language: arguments[index + 2])
                    report += String(format: "%.2f s: ", Date().timeIntervalSince(started)) + text + "\n"
                }
            } catch {
                report += "error: \(error.localizedDescription)"
            }
            try? report.write(to: URL(fileURLWithPath: arguments[index + 3]), atomically: true, encoding: .utf8)
            exit(0)
        }
        RunLoop.main.run()
    }
    // Developer check of the bar's hints: the bar comes up, the mouse goes to its second button for a moment
    // (and back), and the screen around it is saved to <out.png>.
    if let index = CommandLine.arguments.firstIndex(of: "--bar-tooltip-check"), index + 1 < CommandLine.arguments.count {
        let out = CommandLine.arguments[index + 1]
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let bar = QuickActionsBar()
        let settings = Settings()
        let screen = NSScreen.main!.frame
        let rect = NSRect(x: screen.midX - 60, y: screen.midY - 10, width: 120, height: 20)
        let back = NSEvent.mouseLocation
        let warp = { (point: NSPoint) in CGWarpMouseCursorPosition(CGPoint(x: point.x, y: screen.maxY - point.y)) }
        warp(NSPoint(x: rect.midX, y: rect.midY))
        bar.showForCheck(around: rect, settings: settings)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let panel = NSApp.windows.first(where: { $0.isVisible && $0.frame.height < 80 }) else { exit(1) }
            warp(NSPoint(x: panel.frame.minX + 60, y: panel.frame.midY))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let area = panel.frame.insetBy(dx: -120, dy: -60)
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-x", "-R\(Int(area.minX)),\(Int(screen.maxY - area.maxY)),\(Int(area.width)),\(Int(area.height))", out]
                try? task.run()
                task.waitUntilExit()
                warp(back)
                exit(0)
            }
        }
        NSApp.run()
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
