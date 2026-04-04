// Copyright 2026 Link Dupont
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import CoreGraphics

// swiftlint:disable function_body_length
/// Encodes a `CGImage` as a [BlurHash](https://blurha.sh) string.
///
/// BlurHash is a compact representation of an image placeholder, encoding the image's
/// color information into a short ASCII string that can be stored alongside media metadata.
/// Relay uses this when uploading images so that recipients can display a blurred preview
/// while the full image downloads.
///
/// Adapted from [woltapp/blurhash](https://github.com/woltapp/blurhash) (MIT license).
///
/// - Parameters:
///   - cgImage: The source image to encode.
///   - components: The number of DCT components as `(horizontal, vertical)`.
///     Higher values produce more detailed placeholders but longer strings.
///     Defaults to `(4, 3)`.
/// - Returns: The BlurHash string, or `nil` if the image has zero dimensions or cannot be rasterized.
func blurHash(from cgImage: CGImage, numberOfComponents components: (Int, Int) = (4, 3)) -> String? {
// swiftlint:enable function_body_length
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

    // swiftlint:disable:next large_tuple
    var factors: [(Float, Float, Float)] = []
    // swiftlint:disable:next identifier_name
    for j in 0 ..< components.1 {
        // swiftlint:disable:next identifier_name
        for i in 0 ..< components.0 {
            let normalisation: Float = (i == 0 && j == 0) ? 1 : 2
            let factor = multiplyBasisFunction(
                pixels: pixels, width: width, height: height,
                bytesPerRow: bytesPerRow
            // swiftlint:disable:next identifier_name
            ) { x, y in
                normalisation
                    * cos(Float.pi * Float(i) * x / Float(width))
                    * cos(Float.pi * Float(j) * y / Float(height))
            }
            factors.append(factor)
        }
    }

    // swiftlint:disable:next identifier_name
    let dc = factors.first!
    // swiftlint:disable:next identifier_name
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

/// Computes the DCT coefficient for a single basis function over the entire image.
///
/// Iterates every pixel, converting from sRGB to linear color space and multiplying
/// by the cosine basis function. The result is a linear-space (R, G, B) tuple
/// normalized by pixel count.
private func multiplyBasisFunction(
    pixels: UnsafePointer<UInt8>,
    width: Int, height: Int, bytesPerRow: Int,
    basisFunction: (Float, Float) -> Float
// swiftlint:disable:next large_tuple
) -> (Float, Float, Float) {
    // swiftlint:disable:next identifier_name
    var r: Float = 0
    // swiftlint:disable:next identifier_name
    var g: Float = 0
    // swiftlint:disable:next identifier_name
    var b: Float = 0

    // swiftlint:disable:next identifier_name
    for y in 0 ..< height {
        let row = y * bytesPerRow
        // swiftlint:disable:next identifier_name
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

/// Encodes the DC (average color) component as a single packed integer.
private func encodeDC(_ value: (Float, Float, Float)) -> Int { // swiftlint:disable:this large_tuple
    (linearToSRGB(value.0) << 16) + (linearToSRGB(value.1) << 8) + linearToSRGB(value.2)
}

// swiftlint:disable large_tuple
/// Encodes an AC (detail) component, quantizing each channel relative to the maximum AC value.
private func encodeAC(_ value: (Float, Float, Float), maximumValue: Float) -> Int {
// swiftlint:enable large_tuple
    let quantR = Int(max(0, min(18, floor(signPow(value.0 / maximumValue, 0.5) * 9 + 9.5))))
    let quantG = Int(max(0, min(18, floor(signPow(value.1 / maximumValue, 0.5) * 9 + 9.5))))
    let quantB = Int(max(0, min(18, floor(signPow(value.2 / maximumValue, 0.5) * 9 + 9.5))))
    return quantR * 19 * 19 + quantG * 19 + quantB
}

/// Raises `value` to `exp`, preserving the original sign (used for AC quantization).
private func signPow(_ value: Float, _ exp: Float) -> Float {
    copysign(pow(abs(value), exp), value)
}

/// Converts a linear-space color component (0...1) to an sRGB byte value (0...255).
private func linearToSRGB(_ value: Float) -> Int {
    // swiftlint:disable:next identifier_name
    let v = max(0, min(1, value))
    if v <= 0.0031308 { return Int(v * 12.92 * 255 + 0.5) }
    return Int((1.055 * pow(v, 1 / 2.4) - 0.055) * 255 + 0.5)
}

/// Converts an sRGB byte value (0...255) to a linear-space color component (0...1).
private func sRGBToLinear(_ value: UInt8) -> Float {
    // swiftlint:disable:next identifier_name
    let v = Float(value) / 255
    if v <= 0.04045 { return v / 12.92 }
    return pow((v + 0.055) / 1.055, 2.4)
}

/// The 83-character alphabet used by the BlurHash base-83 encoding scheme.
private let base83Characters: [String] = {
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"
        .map { String($0) }
}()

private extension Int {
    /// Encodes this integer as a base-83 string of the given fixed length.
    func encode83(length: Int) -> String {
        var result = ""
        // swiftlint:disable:next identifier_name
        for i in 1...length {
            let divisor = intPow(83, length - i)
            let digit = (self / divisor) % 83
            result += base83Characters[digit]
        }
        return result
    }
}

/// Integer exponentiation (base^exponent) without floating-point conversion.
private func intPow(_ base: Int, _ exponent: Int) -> Int {
    (0 ..< exponent).reduce(1) { val, _ in val * base }
}
