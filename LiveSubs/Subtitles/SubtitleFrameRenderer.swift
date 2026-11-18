import CoreMedia
import CoreVideo
import UIKit

/// Draws the floating subtitle frame into CVPixelBuffers for the PiP display layer.
///
/// Composition follows release-print subtitling: a 2.39:1 frame, two fixed line
/// slots, centred, yellow Helvetica Bold with a black edge. The slots never reflow —
/// when a sentence outgrows two lines, the oldest words leave from the top.
final class SubtitleFrameRenderer {
    let size = CGSize(width: 1434, height: 600)
    private var pool: CVPixelBufferPool?

    struct Content: Equatable {
        var committed: String      // finished English (yellow)
        var tentative: String      // still being heard (white, provisional)
        var badge: String          // "Spanish → English", or a status in SDH brackets
        var original: String = ""  // the line as spoken (e.g. Japanese), small and grey; optional
        var fontScale: CGFloat = 1
    }

    init() {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    func makeSampleBuffer(_ content: Content) -> CMSampleBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pixelBuffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        draw(content)
        UIGraphicsPopContext()
        return wrap(pixelBuffer)
    }

    // MARK: Drawing

    private func draw(_ c: Content) {
        UIColor.black.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))

        // Reel label, top-left: the detected language, in the subtitle face at low strength.
        if !c.badge.isEmpty {
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: Theme.subtitleFont(42),
                .foregroundColor: Theme.subtitleUI.withAlphaComponent(0.5),
            ]
            (c.badge as NSString).draw(at: CGPoint(x: 56, y: 36), withAttributes: badgeAttrs)
        }

        // Two fixed line slots at the foot of the frame. While someone is speaking,
        // the top slot holds the last finished line in yellow and the bottom slot the
        // words still being heard; with nothing provisional, the yellow line may use both.
        let fontSize = 76 * min(max(c.fontScale, 0.7), 1.4)
        let font = Theme.subtitleFont(fontSize)
        let slotWidth = size.width - 120
        let lineHeight = font.lineHeight * 1.08
        let footY = size.height - 48

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        para.minimumLineHeight = lineHeight
        para.maximumLineHeight = lineHeight

        func line(_ text: String, color: UIColor, maxLines: Int) -> NSAttributedString? {
            var words = text.split(separator: " ")
            guard !words.isEmpty else { return nil }
            // Long lines first shrink (down to 72%) so the whole sentence fits; only beyond
            // that do the oldest words leave.
            var size = fontSize
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .foregroundColor: color]
            var s = NSAttributedString(string: words.joined(separator: " "), attributes: attrs)
            while height(of: s, width: slotWidth) > lineHeight * CGFloat(maxLines) + 1, size > fontSize * 0.72 {
                size -= 4
                let smaller = Theme.subtitleFont(size)
                let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineBreakMode = .byWordWrapping
                p.minimumLineHeight = smaller.lineHeight * 1.08; p.maximumLineHeight = smaller.lineHeight * 1.08
                attrs = [.font: smaller, .paragraphStyle: p, .foregroundColor: color]
                s = NSAttributedString(string: words.joined(separator: " "), attributes: attrs)
                if height(of: s, width: slotWidth) <= smaller.lineHeight * 1.08 * CGFloat(maxLines) + 1 { return s }
            }
            // Oldest words leave first; the newest speech always stays on screen.
            while height(of: s, width: slotWidth) > lineHeight * CGFloat(maxLines) + 1, words.count > 1 {
                words.removeFirst()
                s = NSAttributedString(string: words.joined(separator: " "), attributes: attrs)
            }
            return s
        }

        let hasTentative = !c.tentative.isEmpty
        let yellow = line(c.committed, color: Theme.subtitleUI, maxLines: hasTentative ? 1 : 2)
        let white = hasTentative ? line(c.tentative, color: UIColor(white: 1, alpha: 0.86), maxLines: 1) : nil

        var y = footY
        for s in [white, yellow].compactMap({ $0 }) {
            let h = min(height(of: s, width: slotWidth), lineHeight * 2)
            y -= h
            drawEtched(s, in: CGRect(x: 60, y: y, width: slotWidth, height: h))
        }

        // The original words sit above the English, quieter, one line. Scripts without
        // spaces (Japanese) are trimmed by character, the oldest first.
        let original = c.original.trimmingCharacters(in: .whitespacesAndNewlines)
        if !original.isEmpty {
            let small = UIFont.systemFont(ofSize: 48 * min(max(c.fontScale, 0.7), 1.4), weight: .semibold)
            let smallPara = NSMutableParagraphStyle()
            smallPara.alignment = .center
            smallPara.lineBreakMode = .byClipping
            let attrs: [NSAttributedString.Key: Any] = [.font: small, .paragraphStyle: smallPara,
                                                        .foregroundColor: UIColor(white: 1, alpha: 0.72)]
            var text = Substring(original)
            var s = NSAttributedString(string: String(text), attributes: attrs)
            while s.size().width > slotWidth, text.count > 1 {
                text = text.dropFirst(max(1, text.count / 12))
                s = NSAttributedString(string: "…" + text, attributes: attrs)
            }
            let h = ceil(small.lineHeight * 1.2)
            drawEtched(s, in: CGRect(x: 60, y: y - h - 4, width: slotWidth, height: h), edge: 10)
        }
    }

    /// Etched-print edge: a black outline drawn *under* the fill so it never thins the glyphs.
    private func drawEtched(_ text: NSAttributedString, in rect: CGRect, edge width: CGFloat = 16) {
        let edge = NSMutableAttributedString(attributedString: text)
        edge.addAttributes([.strokeColor: UIColor.black, .strokeWidth: width, .foregroundColor: UIColor.black],
                           range: NSRange(location: 0, length: edge.length))
        edge.draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
        text.draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
    }

    private func height(of s: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(s.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil).height)
    }

    private func wrap(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sb)
        if let sb, let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sb
    }
}
