import AppKit

enum ResponseSpeedStatusImage {
    /// Stack the rate above its unit to reduce horizontal menu bar space.
    static func render(rate: String?) -> NSImage {
        let value = NSAttributedString(string: rate ?? "—", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.black,
        ])
        let unit = NSAttributedString(string: "TPS", attributes: [
            .font: NSFont.systemFont(ofSize: 7, weight: .medium),
            .foregroundColor: NSColor.black,
        ])
        let valueSize = value.size()
        let unitSize = unit.size()
        let size = NSSize(width: ceil(max(valueSize.width, unitSize.width)) + 2, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            value.draw(at: NSPoint(x: (size.width - valueSize.width) / 2, y: 9))
            unit.draw(at: NSPoint(x: (size.width - unitSize.width) / 2, y: 0))
            return true
        }
        image.isTemplate = true
        return image
    }
}
