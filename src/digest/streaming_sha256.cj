protected package cjdoc.digest

import std.overflow.*

private let SHA256_CONSTANTS: Array<UInt32> = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
]

private func shaRotateRight(value: UInt32, bits: UInt32): UInt32 {
    (value >> bits) | (value << (32 - bits))
}

protected class StreamingSha256 {
    private var h0: UInt32 = 0x6a09e667
    private var h1: UInt32 = 0xbb67ae85
    private var h2: UInt32 = 0x3c6ef372
    private var h3: UInt32 = 0xa54ff53a
    private var h4: UInt32 = 0x510e527f
    private var h5: UInt32 = 0x9b05688c
    private var h6: UInt32 = 0x1f83d9ab
    private var h7: UInt32 = 0x5be0cd19
    private let pending = Array<Byte>(64, repeat: 0)
    private let words = Array<UInt32>(64, repeat: 0)
    private var pendingSize: Int64 = 0
    private var inputSize: Int64 = 0

    internal static func digestText(text: String): String {
        let digest = StreamingSha256()
        digest.inputSize = text.size
        let fullBytes = text.size - text.size % 64
        var start: Int64 = 0
        while (start < fullBytes) {
            for (index in 0..16) {
                let offset = start + index * 4
                digest.words[index] = (UInt32(text[offset]) << 24) |
                    (UInt32(text[offset + 1]) << 16) |
                    (UInt32(text[offset + 2]) << 8) | UInt32(text[offset + 3])
            }
            digest.compressWords()
            start += 64
        }
        digest.pendingSize = text.size - fullBytes
        for (index in 0..digest.pendingSize) { digest.pending[index] = text[fullBytes + index] }
        digest.finish()
    }

    protected func update(buffer: Array<Byte>, count: Int64): Unit {
        if (count < 0 || count > buffer.size) {
            throw IllegalArgumentException("invalid streaming digest input length")
        }
        inputSize += count
        var offset: Int64 = 0
        while (offset < count) {
            if (pendingSize == 0 && count - offset >= 64) {
                processBlock(buffer, offset)
                offset += 64
                continue
            }
            pending[pendingSize] = buffer[offset]
            offset++
            pendingSize++
            if (pendingSize == 64) {
                processBlock(pending, 0)
                pendingSize = 0
            }
        }
    }

    protected func finish(): String {
        let bitLength = UInt64(inputSize).wrappingMul(8)
        pending[pendingSize] = 0x80
        pendingSize++
        if (pendingSize > 56) {
            while (pendingSize < 64) { pending[pendingSize] = 0; pendingSize++ }
            processBlock(pending, 0)
            pendingSize = 0
        }
        while (pendingSize < 56) { pending[pendingSize] = 0; pendingSize++ }
        var shift: Int64 = 56
        while (shift >= 0) {
            pending[pendingSize] = UInt8((bitLength >> UInt64(shift)) & 0xFF)
            pendingSize++
            shift -= 8
        }
        processBlock(pending, 0)
        pendingSize = 0
        shaHex([h0, h1, h2, h3, h4, h5, h6, h7])
    }

    private func processBlock(input: Array<Byte>, start: Int64): Unit {
        for (index in 0..16) {
            let offset = start + index * 4
            words[index] = (UInt32(input[offset]) << 24) |
                (UInt32(input[offset + 1]) << 16) |
                (UInt32(input[offset + 2]) << 8) | UInt32(input[offset + 3])
        }
        compressWords()
    }

    private func compressWords(): Unit {
        for (index in 16..64) {
            let s0 = shaRotateRight(words[index - 15], 7) ^
                shaRotateRight(words[index - 15], 18) ^ (words[index - 15] >> 3)
            let s1 = shaRotateRight(words[index - 2], 17) ^
                shaRotateRight(words[index - 2], 19) ^ (words[index - 2] >> 10)
            words[index] = words[index - 16].wrappingAdd(s0)
                .wrappingAdd(words[index - 7]).wrappingAdd(s1)
        }
        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4
        var f = h5
        var g = h6
        var h = h7
        for (index in 0..64) {
            let sum1 = shaRotateRight(e, 6) ^ shaRotateRight(e, 11) ^
                shaRotateRight(e, 25)
            let choice = (e & f) ^ ((e ^ 0xFFFFFFFF) & g)
            let temp1 = h.wrappingAdd(sum1).wrappingAdd(choice)
                .wrappingAdd(SHA256_CONSTANTS[index]).wrappingAdd(words[index])
            let sum0 = shaRotateRight(a, 2) ^ shaRotateRight(a, 13) ^
                shaRotateRight(a, 22)
            let temp2 = sum0.wrappingAdd((a & b) ^ (a & c) ^ (b & c))
            h = g; g = f; f = e; e = d.wrappingAdd(temp1)
            d = c; c = b; b = a; a = temp1.wrappingAdd(temp2)
        }
        h0 = h0.wrappingAdd(a); h1 = h1.wrappingAdd(b)
        h2 = h2.wrappingAdd(c); h3 = h3.wrappingAdd(d)
        h4 = h4.wrappingAdd(e); h5 = h5.wrappingAdd(f)
        h6 = h6.wrappingAdd(g); h7 = h7.wrappingAdd(h)
    }
}

private func shaHex(words: Array<UInt32>): String {
    let digits = "0123456789abcdef"
    let out = StringBuilder()
    for (word in words) {
        var shift: Int64 = 28
        while (shift >= 0) {
            let nibble = Int64((word >> UInt32(shift)) & 0xF)
            out.append(digits[nibble..nibble + 1])
            shift -= 4
        }
    }
    out.toString()
}
