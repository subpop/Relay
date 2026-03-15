import CoreGraphics

/// Encodes a CGImage as a BlurHash string with the given number of components.
/// Adapted from https://github.com/woltapp/blurhash (MIT license).
func blurHash(from cgImage: CGImage, numberOfComponents components: (Int, Int) = (4, 3)) -> String? {
    let width = cgImage.width
    let height = cgImage.height

    guard width > 0, height > 0 else { return nil }

    let bytesPerRow = width * 4
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let data = context.data else { return nil }
    let pixels = data.assumingMemoryBound(to: UInt8.self)

    var factors: [(Float, Float, Float)] = []
    for j in 0 ..< components.1 {
        for i in 0 ..< components.0 {
            let normalisation: Float = (i == 0 && j == 0) ? 1 : 2
            let factor = multiplyBasisFunction(
                pixels: pixels, width: width, height: height,
                bytesPerRow: bytesPerRow
            ) { x, y in
                normalisation
                    * cos(Float.pi * Float(i) * x / Float(width))
                    * cos(Float.pi * Float(j) * y / Float(height))
            }
            factors.append(factor)
        }
    }

    let dc = factors.first!
    let ac = factors.dropFirst()

    var hash = ""

    let sizeFlag = (components.0 - 1) + (components.1 - 1) * 9
    hash += sizeFlag.encode83(length: 1)

    let maximumValue: Float
    if !ac.isEmpty {
        let actualMax = ac.map { max(abs($0.0), abs($0.1), abs($0.2)) }.max()!
        let quantised = Int(max(0, min(82, floor(actualMax * 166 - 0.5))))
        maximumValue = Float(quantised + 1) / 166
        hash += quantised.encode83(length: 1)
    } else {
        maximumValue = 1
        hash += 0.encode83(length: 1)
    }

    hash += encodeDC(dc).encode83(length: 4)

    for factor in ac {
        hash += encodeAC(factor, maximumValue: maximumValue).encode83(length: 2)
    }

    return hash
}

// MARK: - Private

private func multiplyBasisFunction(
    pixels: UnsafePointer<UInt8>,
    width: Int, height: Int, bytesPerRow: Int,
    basisFunction: (Float, Float) -> Float
) -> (Float, Float, Float) {
    var r: Float = 0
    var g: Float = 0
    var b: Float = 0

    for y in 0 ..< height {
        let row = y * bytesPerRow
        for x in 0 ..< width {
            let offset = row + x * 4
            let basis = basisFunction(Float(x), Float(y))
            r += basis * sRGBToLinear(pixels[offset])
            g += basis * sRGBToLinear(pixels[offset + 1])
            b += basis * sRGBToLinear(pixels[offset + 2])
        }
    }

    let scale = 1.0 / Float(width * height)
    return (r * scale, g * scale, b * scale)
}

private func encodeDC(_ value: (Float, Float, Float)) -> Int {
    (linearToSRGB(value.0) << 16) + (linearToSRGB(value.1) << 8) + linearToSRGB(value.2)
}

private func encodeAC(_ value: (Float, Float, Float), maximumValue: Float) -> Int {
    let quantR = Int(max(0, min(18, floor(signPow(value.0 / maximumValue, 0.5) * 9 + 9.5))))
    let quantG = Int(max(0, min(18, floor(signPow(value.1 / maximumValue, 0.5) * 9 + 9.5))))
    let quantB = Int(max(0, min(18, floor(signPow(value.2 / maximumValue, 0.5) * 9 + 9.5))))
    return quantR * 19 * 19 + quantG * 19 + quantB
}

private func signPow(_ value: Float, _ exp: Float) -> Float {
    copysign(pow(abs(value), exp), value)
}

private func linearToSRGB(_ value: Float) -> Int {
    let v = max(0, min(1, value))
    if v <= 0.0031308 { return Int(v * 12.92 * 255 + 0.5) }
    return Int((1.055 * pow(v, 1 / 2.4) - 0.055) * 255 + 0.5)
}

private func sRGBToLinear(_ value: UInt8) -> Float {
    let v = Float(value) / 255
    if v <= 0.04045 { return v / 12.92 }
    return pow((v + 0.055) / 1.055, 2.4)
}

private let base83Characters: [String] = {
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"
        .map { String($0) }
}()

private extension Int {
    func encode83(length: Int) -> String {
        var result = ""
        for i in 1...length {
            let divisor = intPow(83, length - i)
            let digit = (self / divisor) % 83
            result += base83Characters[digit]
        }
        return result
    }
}

private func intPow(_ base: Int, _ exponent: Int) -> Int {
    (0 ..< exponent).reduce(1) { val, _ in val * base }
}
