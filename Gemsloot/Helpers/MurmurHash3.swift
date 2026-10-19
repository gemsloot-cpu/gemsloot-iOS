import Foundation

/// JavaScript-faithful MurmurHash3 x86 32-bit — the fingerprint bundle’s `ZB()`.
///
/// Seed `0`, constants `lV/uV/dV/fV/pV` from `bundle.CU_rMswQ.js`,
/// output `(n >>> 0).toString(36)` (see `docs/step-1-ff-payload.md` Branch B).
enum MurmurHash3 {
    /// Hash a string using UTF-16 code units (JS `charCodeAt`), return unsigned base-36.
    static func hashBase36(_ string: String, seed: UInt32 = 0) -> String {
        toBase36(hashX86_32(Array(string.utf16), seed: seed))
    }

    static func hashX86_32(_ units: [UInt16], seed: UInt32 = 0) -> UInt32 {
        let lV: UInt32 = 3_432_918_353
        let uV: UInt32 = 461_845_907
        let dV: UInt32 = 3_864_292_196
        let fV: UInt32 = 2_246_822_507
        let pV: UInt32 = 3_266_489_909

        // Track `n` as JS Number through `Math.imul(n,5)+dV`, then ToInt32 on bitwise ops.
        var n: Double = Double(seed)
        let length = units.count
        let rem = 3 & length
        let bodyEnd = length - rem
        var index = 0

        while index < bodyEnd {
            var k = u8(units[index])
                | u8(units[index + 1]) << 8
                | u8(units[index + 2]) << 16
                | u8(units[index + 3]) << 24
            index += 4
            k = mathImul(k, lV)
            k = rotl(k, 15)
            k = mathImul(k, uV)
            n = Double(rotl(toInt32Bits(n) ^ k, 13))
            n = Double(mathImul(toInt32Bits(n), 5)) + Double(dV)
        }

        var k: UInt32 = 0
        switch rem {
        case 3:
            k ^= u8(units[index + 2]) << 16
            fallthrough
        case 2:
            k ^= u8(units[index + 1]) << 8
            fallthrough
        case 1:
            k ^= u8(units[index])
            k = mathImul(k, lV)
            k = rotl(k, 15)
            k = mathImul(k, uV)
            n = Double(toInt32Bits(n) ^ k)
        default:
            break
        }

        var h = toInt32Bits(n) ^ UInt32(length)
        h ^= h >> 16
        h = mathImul(h, fV)
        h ^= h >> 13
        h = mathImul(h, pV)
        h ^= h >> 16
        return h
    }

    private static func u8(_ unit: UInt16) -> UInt32 { UInt32(unit & 0xFF) }

    /// `Math.imul` — 32-bit integer multiply with int32 truncation.
    private static func mathImul(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let product = Int64(Int32(bitPattern: a)) * Int64(Int32(bitPattern: b))
        return UInt32(bitPattern: Int32(truncatingIfNeeded: product))
    }

    /// Bundle `XB`: `e<<t|e>>>32-t`.
    private static func rotl(_ value: UInt32, _ t: UInt32) -> UInt32 {
        (value << t) | (value >> (32 - t))
    }

    /// ECMAScript ToInt32 bit pattern (sufficient for our integer-valued Numbers).
    private static func toInt32Bits(_ value: Double) -> UInt32 {
        UInt32(bitPattern: Int32(truncatingIfNeeded: Int64(value)))
    }

    private static func toBase36(_ value: UInt32) -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        if value == 0 { return "0" }
        var n = value
        var chars: [Character] = []
        while n > 0 {
            chars.append(digits[Int(n % 36)])
            n /= 36
        }
        return String(chars.reversed())
    }
}
