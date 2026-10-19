import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

/// On-device Vision features: text recognition, subject lifting, face detection.
public enum VisionKit {
    public struct TextLine: Sendable {
        public let text: String
        /// Pixel rect with a top-left origin.
        public let rect: CGRect
    }

    public static func recognizeLines(in image: CGImage) throws -> [TextLine] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        let W = CGFloat(image.width), H = CGFloat(image.height)
        return (req.results ?? []).compactMap { obs in
            guard let s = obs.topCandidates(1).first?.string, !s.isEmpty else { return nil }
            let b = obs.boundingBox
            return TextLine(text: s, rect: CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H))
        }
    }

    /// Text in reading order, with blank lines between paragraphs.
    public static func recognizeText(in image: CGImage) throws -> String {
        let lines = try recognizeLines(in: image)
        guard !lines.isEmpty else { return "" }
        let sorted = lines.sorted { a, b in
            if abs(a.rect.midY - b.rect.midY) < min(a.rect.height, b.rect.height) * 0.5 { return a.rect.minX < b.rect.minX }
            return a.rect.midY < b.rect.midY
        }
        var rows: [[TextLine]] = []
        for line in sorted {
            if let last = rows.last?.last, abs(last.rect.midY - line.rect.midY) < min(last.rect.height, line.rect.height) * 0.5 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        var out = ""
        var prevBottom: CGFloat? = nil
        var prevHeight: CGFloat = 0
        for row in rows {
            let top = row.map(\.rect.minY).min()!
            let height = row.map(\.rect.height).max()!
            if let pb = prevBottom, top - pb > max(prevHeight, height) * 0.9 { out += "\n" }
            out += row.map(\.text).joined(separator: "  ") + "\n"
            prevBottom = row.map(\.rect.maxY).max()!
            prevHeight = height
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func faceRects(in image: CGImage) throws -> [CGRect] {
        let req = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        let W = CGFloat(image.width), H = CGFloat(image.height)
        return (req.results ?? []).map { o in
            let b = o.boundingBox
            // Pad a little so hair/chin are covered too.
            let r = CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H)
            return r.insetBy(dx: -r.width * 0.15, dy: -r.height * 0.2)
        }
    }

    /// Cuts out the main subject(s) and returns an image with a transparent background.
    public static func removeBackground(_ image: CGImage) throws -> CGImage {
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([req])
        guard let result = req.results?.first, !result.allInstances.isEmpty else {
            throw TangeloError.failed("Couldn't find a subject in this image.")
        }
        let mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        let source = CIImage(cgImage: image)
        let maskImage = CIImage(cvPixelBuffer: mask)
        let sx = source.extent.width / maskImage.extent.width, sy = source.extent.height / maskImage.extent.height
        let scaledMask = maskImage.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let out = source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: source.extent),
            kCIInputMaskImageKey: scaledMask,
        ])
        guard let cg = CIContext().createCGImage(out, from: source.extent, format: .RGBA8, colorSpace: ImageKit.sRGB) else {
            throw TangeloError.failed("Couldn't render the cut-out.")
        }
        return cg
    }
}
