#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// BIP-340 Schnorr signature verification over secp256k1, the check Nostr events are signed for
/// (Android does it with a native secp256k1 library; swift-crypto has no such curve).
///
/// Verification only, from public data, so nothing here has to be constant-time. The arithmetic
/// is 256-bit numbers as four 64-bit limbs, field operations reduced with p = 2^256 − 2^32 − 977,
/// and points in Jacobian coordinates.
public enum Schnorr {
    /// Whether `signature` (64 bytes) signs `message` (32 bytes) under the x-only `publicKey`.
    public static func verify(signature: [UInt8], message: [UInt8], publicKey: [UInt8]) -> Bool {
        guard signature.count == 64, message.count == 32, publicKey.count == 32 else { return false }
        let px = U256(bytes: publicKey)
        guard px < Field.p, let point = Curve.liftX(px) else { return false }
        let r = U256(bytes: Array(signature[0..<32]))
        let s = U256(bytes: Array(signature[32..<64]))
        guard r < Field.p, s < Curve.n else { return false }
        var e = U256(bytes: taggedHash("BIP0340/challenge", Array(signature[0..<32]) + publicKey + message))
        if !(e < Curve.n) { e = e.subtracting(Curve.n).value }
        let negE = e.isZero ? U256.zero : Curve.n.subtracting(e).value
        // R = s·G − e·P
        let sum = Curve.add(Curve.multiply(Curve.generator, by: s), Curve.multiply(point, by: negE))
        guard let affine = Curve.affine(sum), affine.y.isEven else { return false }
        return affine.x == r
    }

    static func taggedHash(_ tag: String, _ data: [UInt8]) -> [UInt8] {
        let tagHash = Array(SHA256.hash(data: Data(tag.utf8)))
        return Array(SHA256.hash(data: Data(tagHash + tagHash + data)))
    }
}

// MARK: - 256-bit numbers

struct U256: Equatable, Comparable {
    /// Little-endian limbs.
    var limbs: [UInt64]

    static let zero = U256(limbs: [0, 0, 0, 0])
    static let one = U256(limbs: [1, 0, 0, 0])

    init(limbs: [UInt64]) { self.limbs = limbs }

    init(bytes: [UInt8]) {
        var limbs = [UInt64](repeating: 0, count: 4)
        for (index, byte) in bytes.suffix(32).reversed().enumerated() {
            limbs[index / 8] |= UInt64(byte) << (8 * UInt64(index % 8))
        }
        self.limbs = limbs
    }

    init(hex: String) {
        var bytes: [UInt8] = []
        var chars = Array(hex)
        if chars.count % 2 == 1 { chars.insert("0", at: 0) }
        for index in stride(from: 0, to: chars.count, by: 2) {
            bytes.append(UInt8(String(chars[index...index + 1]), radix: 16) ?? 0)
        }
        self.init(bytes: bytes)
    }

    var isZero: Bool { limbs.allSatisfy { $0 == 0 } }
    var isEven: Bool { limbs[0] & 1 == 0 }

    func bit(_ index: Int) -> Bool { (limbs[index / 64] >> UInt64(index % 64)) & 1 == 1 }

    static func < (lhs: U256, rhs: U256) -> Bool {
        for index in (0..<4).reversed() where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }

    func adding(_ other: U256) -> (value: U256, carry: Bool) {
        var out = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for index in 0..<4 {
            let (a, o1) = limbs[index].addingReportingOverflow(other.limbs[index])
            let (b, o2) = a.addingReportingOverflow(carry)
            out[index] = b
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return (U256(limbs: out), carry != 0)
    }

    func subtracting(_ other: U256) -> (value: U256, borrow: Bool) {
        var out = [UInt64](repeating: 0, count: 4)
        var borrow: UInt64 = 0
        for index in 0..<4 {
            let (a, o1) = limbs[index].subtractingReportingOverflow(other.limbs[index])
            let (b, o2) = a.subtractingReportingOverflow(borrow)
            out[index] = b
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return (U256(limbs: out), borrow != 0)
    }
}

// MARK: - The field, mod p

enum Field {
    static let p = U256(hex: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F")
    /// 2^256 mod p.
    static let c: UInt64 = 0x1000003D1

    static func add(_ a: U256, _ b: U256) -> U256 {
        let (sum, carry) = a.adding(b)
        if carry || !(sum < p) { return sum.subtracting(p).value }
        return sum
    }

    static func sub(_ a: U256, _ b: U256) -> U256 {
        let (difference, borrow) = a.subtracting(b)
        return borrow ? difference.adding(p).value : difference
    }

    static func mul(_ a: U256, _ b: U256) -> U256 {
        // Schoolbook product into eight limbs.
        var wide = [UInt64](repeating: 0, count: 8)
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                let (high, low) = a.limbs[i].multipliedFullWidth(by: b.limbs[j])
                let (s1, o1) = wide[i + j].addingReportingOverflow(low)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                wide[i + j] = s2
                carry = high &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            wide[i + 4] = carry
        }
        return reduce(wide)
    }

    static func square(_ a: U256) -> U256 { mul(a, a) }

    /// A 512-bit number mod p: high·2^256 + low ≡ high·c + low, folded until it fits.
    static func reduce(_ wide: [UInt64]) -> U256 {
        var low = Array(wide[0..<4])
        var high = Array(wide[4..<8])
        while high.contains(where: { $0 != 0 }) {
            var product = [UInt64](repeating: 0, count: 5)
            var carry: UInt64 = 0
            for index in 0..<4 {
                let (h, l) = high[index].multipliedFullWidth(by: c)
                let (sum, overflow) = l.addingReportingOverflow(carry)
                product[index] = sum
                carry = h &+ (overflow ? 1 : 0)
            }
            product[4] = carry
            var next = [UInt64](repeating: 0, count: 5)
            var addCarry: UInt64 = 0
            for index in 0..<5 {
                let lowLimb = index < 4 ? low[index] : 0
                let (s1, o1) = lowLimb.addingReportingOverflow(product[index])
                let (s2, o2) = s1.addingReportingOverflow(addCarry)
                next[index] = s2
                addCarry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
            }
            low = Array(next[0..<4])
            high = [next[4] &+ addCarry, 0, 0, 0]
        }
        var result = U256(limbs: low)
        while !(result < p) { result = result.subtracting(p).value }
        return result
    }

    static func pow(_ base: U256, _ exponent: U256) -> U256 {
        var result = U256.one
        for index in (0..<256).reversed() {
            result = square(result)
            if exponent.bit(index) { result = mul(result, base) }
        }
        return result
    }

    static func inverse(_ a: U256) -> U256 { pow(a, p.subtracting(U256(limbs: [2, 0, 0, 0])).value) }

    /// (p + 1) / 4, for square roots (p ≡ 3 mod 4).
    static let sqrtExponent = U256(hex: "3FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFBFFFFF0C")
}

// MARK: - The curve y² = x³ + 7

enum Curve {
    static let n = U256(hex: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")
    static let generator = Jacobian(
        x: U256(hex: "79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798"),
        y: U256(hex: "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8"),
        z: .one
    )

    struct Jacobian {
        var x: U256
        var y: U256
        var z: U256
        var isInfinity: Bool { z.isZero }
        static let infinity = Jacobian(x: .one, y: .one, z: .zero)
    }

    /// The point with x and an even y (BIP-340's lift_x), nil when x isn't on the curve.
    static func liftX(_ x: U256) -> Jacobian? {
        let c = Field.add(Field.mul(Field.square(x), x), U256(limbs: [7, 0, 0, 0]))
        let y = Field.pow(c, Field.sqrtExponent)
        guard Field.square(y) == c else { return nil }
        return Jacobian(x: x, y: y.isEven ? y : Field.sub(.zero, y), z: .one)
    }

    static func double(_ point: Jacobian) -> Jacobian {
        if point.isInfinity || point.y.isZero { return .infinity }
        let a = Field.square(point.x)
        let b = Field.square(point.y)
        let c = Field.square(b)
        let xb = Field.square(Field.add(point.x, b))
        let d = Field.add(Field.sub(Field.sub(xb, a), c), Field.sub(Field.sub(xb, a), c))
        let e = Field.add(Field.add(a, a), a)
        let f = Field.square(e)
        let x3 = Field.sub(f, Field.add(d, d))
        let eightC = Field.add(Field.add(Field.add(c, c), Field.add(c, c)), Field.add(Field.add(c, c), Field.add(c, c)))
        let y3 = Field.sub(Field.mul(e, Field.sub(d, x3)), eightC)
        let z3 = Field.mul(Field.add(point.y, point.y), point.z)
        return Jacobian(x: x3, y: y3, z: z3)
    }

    static func add(_ p1: Jacobian, _ p2: Jacobian) -> Jacobian {
        if p1.isInfinity { return p2 }
        if p2.isInfinity { return p1 }
        let z1z1 = Field.square(p1.z)
        let z2z2 = Field.square(p2.z)
        let u1 = Field.mul(p1.x, z2z2)
        let u2 = Field.mul(p2.x, z1z1)
        let s1 = Field.mul(Field.mul(p1.y, p2.z), z2z2)
        let s2 = Field.mul(Field.mul(p2.y, p1.z), z1z1)
        if u1 == u2 { return s1 == s2 ? double(p1) : .infinity }
        let h = Field.sub(u2, u1)
        let r = Field.sub(s2, s1)
        let h2 = Field.square(h)
        let h3 = Field.mul(h, h2)
        let u1h2 = Field.mul(u1, h2)
        let x3 = Field.sub(Field.sub(Field.square(r), h3), Field.add(u1h2, u1h2))
        let y3 = Field.sub(Field.mul(r, Field.sub(u1h2, x3)), Field.mul(s1, h3))
        let z3 = Field.mul(Field.mul(h, p1.z), p2.z)
        return Jacobian(x: x3, y: y3, z: z3)
    }

    static func multiply(_ point: Jacobian, by scalar: U256) -> Jacobian {
        var result = Jacobian.infinity
        for index in (0..<256).reversed() {
            result = double(result)
            if scalar.bit(index) { result = add(result, point) }
        }
        return result
    }

    static func affine(_ point: Jacobian) -> (x: U256, y: U256)? {
        guard !point.isInfinity else { return nil }
        let zInverse = Field.inverse(point.z)
        let zInverse2 = Field.square(zInverse)
        return (Field.mul(point.x, zInverse2), Field.mul(point.y, Field.mul(zInverse2, zInverse)))
    }
}
