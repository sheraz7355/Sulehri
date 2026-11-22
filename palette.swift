// Builds Sulehri's colors from the desktop wallpaper.
// It finds the most vivid color (accent), the strongest different color (second),
// and the tint of the shadows and highlights, then derives a full theme from them.

import Cocoa
import CoreImage

struct HSL {
    var h: Double   // 0..<360
    var s: Double   // 0...1
    var l: Double   // 0...1

    init(_ h: Double, _ s: Double, _ l: Double) {
        self.h = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        self.s = min(1, max(0, s)); self.l = min(1, max(0, l))
    }

    init(r: Double, g: Double, b: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        let l = (mx + mn) / 2
        var h = 0.0, s = 0.0
        if d > 0.0001 {
            s = d / (1 - abs(2 * l - 1))
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h *= 60
        }
        self.init(h, s, l)
    }

    var rgb: (Double, Double, Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }
    private var bytes: (Int, Int, Int) {
        let (r, g, b) = rgb
        return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
    var css: String { let (r, g, b) = bytes; return String(format: "#%02X%02X%02X", r, g, b) }
    func rgba(_ a: Double) -> String { let (r, g, b) = bytes; return "rgba(\(r),\(g),\(b),\(a))" }
    var color: NSColor { let (r, g, b) = rgb; return NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

func hueDistance(_ a: Double, _ b: Double) -> Double {
    let d = abs(a - b).truncatingRemainder(dividingBy: 360)
    return min(d, 360 - d)
}

struct WallTheme {
    var source: String
    var dark: Bool
    var vars: [String: String]      // CSS variables for the board
    var backdrop: String            // small blurred copy of the wallpaper (data URL), "" if none
    // Colors for the native parts (top bar, cursor, drawings on screen)
    var bg, line, text, muted, idle, listening, thinking, speaking, ink, note, noteText: HSL
    var swatches: [String]          // four colors that show the palette (history cards)
}

func currentWallpaperURL() -> URL? {
    guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
    return url
}

func makeWallTheme(from url: URL) -> WallTheme? {
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceThumbnailMaxPixelSize: 480,
                                 kCGImageSourceCreateThumbnailWithTransform: true]
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }

    // ---- read a small copy of the picture
    let w = 120, h = max(1, thumb.height * 120 / max(thumb.width, 1))
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let drawn: Bool = buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard drawn else { return nil }

    // ---- sort the pixels: vivid ones by hue, plus the shadows and the highlights
    let binCount = 24
    var score = [Double](repeating: 0, count: binCount)
    var binRGB = [(Double, Double, Double)](repeating: (0, 0, 0), count: binCount)
    var darkSum = (0.0, 0.0, 0.0, 0.0), lightSum = (0.0, 0.0, 0.0, 0.0)
    var darkBins = [(Double, Double, Double, Double)](repeating: (0, 0, 0, 0), count: 12)   // shadows, grouped by hue
    var lumSum = 0.0
    for i in stride(from: 0, to: buf.count, by: 4) {
        let r = Double(buf[i]) / 255, g = Double(buf[i + 1]) / 255, b = Double(buf[i + 2]) / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        lumSum += lum
        if lum < 0.2 {
            darkSum = (darkSum.0 + r, darkSum.1 + g, darkSum.2 + b, darkSum.3 + 1)
            let chroma = mx - mn
            if chroma > 0.03 {
                let bin = min(11, Int(HSL(r: r, g: g, b: b).h / 30))
                darkBins[bin] = (darkBins[bin].0 + r, darkBins[bin].1 + g, darkBins[bin].2 + b, darkBins[bin].3 + 1)
            }
        }
        if lum > 0.7 { lightSum = (lightSum.0 + r, lightSum.1 + g, lightSum.2 + b, lightSum.3 + 1) }
        let sat = mx > 0 ? (mx - mn) / mx : 0
        if sat > 0.35, mx > 0.3 {
            let wgt = pow(sat * mx, 2)     // vivid pixels count much more than dull ones
            let bin = min(binCount - 1, Int(HSL(r: r, g: g, b: b).h / 360 * Double(binCount)))
            score[bin] += wgt
            binRGB[bin] = (binRGB[bin].0 + r * wgt, binRGB[bin].1 + g * wgt, binRGB[bin].2 + b * wgt)
        }
    }
    let pixels = Double(w * h)
    let dark = lumSum / pixels < 0.5
    func binColor(_ i: Int) -> HSL {
        let s = max(score[i], 0.0001)
        return HSL(r: binRGB[i].0 / s, g: binRGB[i].1 / s, b: binRGB[i].2 / s)
    }
    func binHue(_ i: Int) -> Double { (Double(i) + 0.5) * 360 / Double(binCount) }
    func smooth(_ i: Int) -> Double {
        score[(i + binCount - 1) % binCount] * 0.5 + score[i] + score[(i + 1) % binCount] * 0.5
    }

    // ---- accent: the most vivid color. second: the strongest color that is clearly different.
    let order = (0..<binCount).sorted { smooth($0) > smooth($1) }
    var accent = HSL(22, 0.85, 0.55), second = HSL(200, 0.5, 0.55)
    if let a = order.first, smooth(a) > 0.5 {
        accent = binColor(a)
        if let b = order.first(where: { hueDistance(binHue($0), binHue(a)) >= 60 && smooth($0) > smooth(a) * 0.01 }) {
            second = binColor(b)
        } else {
            second = HSL(accent.h + 180, 0.45, 0.55)
        }
    }
    // third: a close neighbour of the accent (like lantern gold next to maple orange), away from the second color.
    let up = accent.h + 30, down = accent.h - 30
    let third = HSL(hueDistance(up, second.h) >= hueDistance(down, second.h) ? up : down, 0.8, 0.6)

    // The shadows' own color. An average of all dark pixels turns muddy, so group them by hue and prefer
    // a shadow color that contrasts with the accent (so the accent glows against it, like in the picture).
    var darkTint = HSL(second.h, 0.3, 0.1)
    let darkTotal = darkBins.reduce(0) { $0 + $1.3 }
    func tint(_ b: (Double, Double, Double, Double)) -> HSL { HSL(r: b.0 / b.3, g: b.1 / b.3, b: b.2 / b.3) }
    let ranked = darkBins.filter { $0.3 > 0 }.sorted { $0.3 > $1.3 }
    if let contrast = ranked.first(where: { $0.3 > darkTotal * 0.12 && hueDistance(tint($0).h, accent.h) >= 60 }) {
        darkTint = tint(contrast)
    } else if let best = ranked.first, darkTotal > 0.5 {
        darkTint = tint(best)
    } else if darkSum.3 > pixels * 0.01 {
        darkTint = HSL(r: darkSum.0 / darkSum.3, g: darkSum.1 / darkSum.3, b: darkSum.2 / darkSum.3)
    }
    let lightTint = lightSum.3 > pixels * 0.01
        ? HSL(r: lightSum.0 / lightSum.3, g: lightSum.1 / lightSum.3, b: lightSum.2 / lightSum.3) : HSL(accent.h + 20, 0.4, 0.9)

    // ---- build the theme
    let aH = accent.h, sH = second.h, tH = third.h
    let dH = darkTint.h, lH = lightTint.h
    let goodH = 135.0, badH = hueDistance(aH, 350) < 25 ? 330.0 : 350.0
    var v: [String: String] = [:]
    let t: (bg: HSL, line: HSL, text: HSL, muted: HSL, main: HSL, acc: HSL, alt: HSL, good: HSL)
    if dark {
        let bS = min(0.5, max(0.28, darkTint.s))
        let bg = HSL(dH, bS, 0.085), panel = HSL(dH, bS, 0.115), panel2 = HSL(dH, bS * 0.9, 0.155)
        let line = HSL(dH, bS * 0.8, 0.24), softS = HSL(dH, bS * 0.7, 0.34)
        let text = HSL(lH, 0.45, 0.93), soft = HSL(lH, 0.25, 0.82), muted = HSL(dH, 0.2, 0.64)
        let acc = HSL(aH, max(0.85, accent.s), 0.60), main = HSL(sH, min(0.6, max(0.42, second.s)), 0.68)
        let alt = HSL(tH, 0.85, 0.70), good = HSL(goodH, 0.42, 0.62), bad = HSL(badH, 0.82, 0.68)
        v = ["--bg": bg.css, "--panel": panel.css, "--panel2": panel2.css, "--line": line.css,
             "--text": text.css, "--soft": soft.css, "--muted": muted.css,
             "--me": HSL(sH, 0.45, 0.30).css, "--meText": text.css,
             "--brand1": acc.css, "--brand2": alt.css, "--now": acc.css, "--nowGlow": acc.rgba(0.24),
             "--main": main.css, "--mainF": HSL(sH, 0.42, 0.17).css,
             "--acc": acc.css, "--accF": HSL(aH, 0.55, 0.17).css,
             "--good": good.css, "--goodF": HSL(goodH, 0.35, 0.15).css,
             "--bad": bad.css, "--badF": HSL(badH, 0.45, 0.17).css,
             "--alt": alt.css, "--altF": HSL(tH, 0.5, 0.16).css,
             "--softF": panel2.css, "--softS": softS.css,
             "--edge": HSL(lH, 0.2, 0.76).css, "--pen": HSL(tH, 0.95, 0.72).css,
             "--ty": HSL(tH, 0.9, 0.72).css, "--tg": HSL(goodH, 0.5, 0.70).css, "--tb": HSL(sH, 0.6, 0.76).css,
             "--tp": HSL(aH, 0.95, 0.70).css, "--tr": HSL(badH, 0.9, 0.74).css,
             "--glow": acc.rgba(0.55), "--veil1": bg.rgba(0.80), "--veil2": bg.rgba(0.93),
             "--glass": panel.rgba(0.72), "--glass2": panel2.rgba(0.86)]
        t = (bg, line, text, muted, main, acc, alt, good)
    } else {
        let lS = min(0.55, max(0.3, lightTint.s))
        let bg = HSL(lH, lS, 0.955), panel = HSL(lH, lS * 0.8, 0.92), panel2 = HSL(lH, lS, 0.985)
        let line = HSL(lH, lS * 0.6, 0.84), softS = HSL(lH, lS * 0.55, 0.75)
        let text = HSL(dH, 0.38, 0.16), soft = HSL(dH, 0.25, 0.28), muted = HSL(dH, 0.12, 0.48)
        let acc = HSL(aH, max(0.75, accent.s), 0.50), main = HSL(sH, min(0.55, max(0.4, second.s)), 0.42)
        let alt = HSL(tH, 0.75, 0.44), good = HSL(goodH, 0.45, 0.36), bad = HSL(badH, 0.65, 0.48)
        v = ["--bg": bg.css, "--panel": panel.css, "--panel2": panel2.css, "--line": line.css,
             "--text": text.css, "--soft": soft.css, "--muted": muted.css,
             "--me": main.css, "--meText": "#FFFFFF",
             "--brand1": acc.css, "--brand2": alt.css, "--now": acc.css, "--nowGlow": acc.rgba(0.16),
             "--main": main.css, "--mainF": HSL(sH, 0.5, 0.93).css,
             "--acc": acc.css, "--accF": HSL(aH, 0.85, 0.92).css,
             "--good": good.css, "--goodF": HSL(goodH, 0.4, 0.92).css,
             "--bad": bad.css, "--badF": HSL(badH, 0.7, 0.94).css,
             "--alt": alt.css, "--altF": HSL(tH, 0.8, 0.91).css,
             "--softF": panel2.css, "--softS": softS.css,
             "--edge": HSL(dH, 0.15, 0.38).css, "--pen": acc.css,
             "--ty": HSL(aH, 0.85, 0.42).css, "--tg": HSL(goodH, 0.5, 0.30).css, "--tb": HSL(sH, 0.55, 0.36).css,
             "--tp": HSL(tH, 0.75, 0.36).css, "--tr": HSL(badH, 0.65, 0.42).css,
             "--glow": acc.rgba(0.0), "--veil1": bg.rgba(0.84), "--veil2": bg.rgba(0.94),
             "--glass": panel.rgba(0.74), "--glass2": panel2.rgba(0.88)]
        t = (bg, line, text, muted, main, acc, alt, good)
    }

    // ---- a small, blurred copy of the wallpaper for the board's backdrop
    var backdrop = ""
    let ci = CIImage(cgImage: thumb)
    let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: 9).cropped(to: ci.extent)
    if let data = CIContext().jpegRepresentation(of: blurred, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                 options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]) {
        backdrop = "data:image/jpeg;base64," + data.base64EncodedString()
    }

    return WallTheme(source: url.path, dark: dark, vars: v, backdrop: backdrop,
                     bg: dark ? HSL(dH, t.bg.s, 0.115) : t.bg, line: t.line, text: t.text, muted: t.muted,
                     idle: dark ? t.main : HSL(sH, 0.6, 0.55), listening: dark ? t.good : HSL(goodH, 0.55, 0.45),
                     thinking: dark ? t.alt : HSL(tH, 0.85, 0.5), speaking: t.acc,
                     ink: HSL(aH, 0.95, 0.58), note: HSL(tH, 0.9, 0.82), noteText: HSL(dH, 0.5, 0.14),
                     swatches: [HSL(dH, 0.45, 0.2).css, t.acc.css, t.alt.css, t.main.css])
}
