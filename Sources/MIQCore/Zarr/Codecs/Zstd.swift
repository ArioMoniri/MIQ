import Foundation

/// Pure-Swift Zstandard decompressor, written from RFC 8878.
///
/// Supports everything a compressor emits without a dictionary: raw, RLE and
/// compressed blocks; raw, RLE, Huffman (one- and four-stream) and treeless
/// literals; predefined, RLE, FSE-compressed and repeat sequence tables; repeat
/// offsets; multiple concatenated frames; skippable frames; and the optional
/// XXH64 content checksum. Frames that name a dictionary are rejected.
///
/// The decoder never allocates from header fields: output goes into a buffer
/// whose size the *caller* chooses (the expected chunk size, already bounded by
/// `ZarrArrayMetadata.maxChunkBytes`), and every literal, match and table read
/// is bounds-checked, so a truncated or hostile stream throws instead of
/// trapping. Matches may reach back to the start of the current frame (the
/// whole frame is in memory), which subsumes any window size.
enum ZstdDecoder {
    static let frameMagic: UInt32 = 0xFD2F_B528
    /// Skippable frames use magics `0x184D2A50 … 0x184D2A5F`.
    static let skippableMagicMask: UInt32 = 0xFFFF_FFF0
    static let skippableMagic: UInt32 = 0x184D_2A50
    /// Largest decompressed (and compressed) block: `Block_Maximum_Size`.
    static let maxBlockSize = 128 * 1024

    /// Decompresses every frame in `input`, producing at most `capacity` bytes.
    /// Throws when the content would exceed `capacity`.
    static func decompress(_ input: Data, capacity: Int, verifyChecksum: Bool = true) throws -> Data {
        guard capacity >= 0 else { throw corrupt("negative capacity") }
        var output = Data(count: capacity)
        let produced = try input.withUnsafeBytes { inRaw in
            try output.withUnsafeMutableBytes { outRaw in
                try decompress(inRaw, into: outRaw, verifyChecksum: verifyChecksum)
            }
        }
        return produced == capacity ? output : output.prefix(produced)
    }

    /// Decompresses `input` into `output`, returning the number of bytes written.
    static func decompress(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer,
                           verifyChecksum: Bool = true) throws -> Int {
        var stream = ZstdStream(input: input, output: output, verifyChecksum: verifyChecksum)
        return try stream.run()
    }

    static func corrupt(_ message: String) -> MIQError {
        .malformedFile("Zstandard data is corrupt (\(message))")
    }
}

// MARK: - Bit readers

/// Reads a Zstandard backward bitstream: a little-endian bit string whose
/// highest set bit is a padding marker, consumed from just below the marker
/// towards bit 0. `position` counts the bits still unread; it goes negative
/// when a corrupt stream is over-read (reads then return zero bits).
private struct BackwardBitReader {
    let base: UnsafePointer<UInt8>
    let count: Int
    var position: Int

    init(_ base: UnsafePointer<UInt8>, count: Int) throws {
        guard count > 0 else { throw ZstdDecoder.corrupt("empty bitstream") }
        let last = base[count - 1]
        guard last != 0 else { throw ZstdDecoder.corrupt("bitstream has no end marker") }
        self.base = base
        self.count = count
        position = (count - 1) * 8 + (7 - last.leadingZeroBitCount)
    }

    /// Bits `[bit, bit + n)` of the stream, `n <= 56`, `bit + n <= count * 8`.
    @inline(__always)
    private func bits(at bit: Int, _ n: Int) -> UInt64 {
        let byte = bit >> 3
        var word: UInt64
        if byte + 8 <= count {
            word = UInt64(littleEndian: UnsafeRawPointer(base + byte).loadUnaligned(as: UInt64.self))
        } else {
            word = 0
            for i in 0..<(count - byte) { word |= UInt64(base[byte + i]) << UInt64(8 * i) }
        }
        return (word >> UInt64(bit & 7)) & ((1 << UInt64(n)) - 1)
    }

    /// The next `n` bits (most significant first), zero-padded past bit 0.
    @inline(__always)
    func peek(_ n: Int) -> UInt64 {
        if position >= n { return bits(at: position - n, n) }
        guard position > 0 else { return 0 }
        return bits(at: 0, position) << UInt64(n - position)
    }

    @inline(__always)
    mutating func read(_ n: Int) -> UInt64 {
        guard n > 0 else { return 0 }
        let value = peek(n)
        position -= n
        return value
    }
}

// MARK: - FSE tables

/// An FSE decoding table, one packed entry per state:
/// `symbol | nbBits << 8 | newStateBase << 16`.
private struct FSETable {
    var entries: [UInt32]
    var accuracyLog: Int

    @inline(__always) static func symbol(_ e: UInt32) -> Int { Int(e & 0xFF) }
    @inline(__always) static func bitCount(_ e: UInt32) -> Int { Int((e >> 8) & 0xFF) }
    @inline(__always) static func base(_ e: UInt32) -> Int { Int(e >> 16) }

    static func rle(_ symbol: UInt8) -> FSETable { FSETable(entries: [UInt32(symbol)], accuracyLog: 0) }

    /// Builds the decoding table for normalised `probabilities` (−1 = "less
    /// than one"), which must sum (in absolute value) to `1 << accuracyLog`.
    static func build(probabilities: [Int], accuracyLog: Int) throws -> FSETable {
        let size = 1 << accuracyLog
        var symbols = [UInt8](repeating: 0, count: size)
        var next = [Int](repeating: 0, count: probabilities.count)
        var high = size - 1
        for (s, p) in probabilities.enumerated() where p == -1 {
            guard high >= 0 else { throw ZstdDecoder.corrupt("FSE table overfull") }
            symbols[high] = UInt8(s)
            high -= 1
            next[s] = 1
        }
        let step = (size >> 1) + (size >> 3) + 3
        let mask = size - 1
        var position = 0
        for (s, p) in probabilities.enumerated() where p > 0 {
            next[s] = p
            for _ in 0..<p {
                symbols[position] = UInt8(s)
                repeat { position = (position + step) & mask } while position > high
            }
        }
        guard position == 0 else { throw ZstdDecoder.corrupt("FSE probabilities don't fill the table") }
        var entries = [UInt32](repeating: 0, count: size)
        for u in 0..<size {
            let s = Int(symbols[u])
            let state = next[s]
            next[s] += 1
            guard state > 0 else { throw ZstdDecoder.corrupt("FSE state for an absent symbol") }
            let nbBits = accuracyLog - (Int.bitWidth - 1 - state.leadingZeroBitCount)
            guard nbBits >= 0 else { throw ZstdDecoder.corrupt("FSE state out of range") }
            let newBase = (state << nbBits) - size
            guard newBase >= 0, newBase < size else { throw ZstdDecoder.corrupt("FSE state out of range") }
            entries[u] = UInt32(s) | UInt32(nbBits) << 8 | UInt32(newBase) << 16
        }
        return FSETable(entries: entries, accuracyLog: accuracyLog)
    }

    /// Parses an FSE table description starting at `start` (RFC 8878 §4.1.1),
    /// returning the table and the number of bytes the description used.
    static func read(_ input: UnsafePointer<UInt8>, start: Int, end: Int,
                     maxAccuracyLog: Int, maxSymbol: Int) throws -> (FSETable, Int) {
        let available = end - start
        guard available > 0 else { throw ZstdDecoder.corrupt("missing FSE table description") }
        var bitOffset = 0
        /// `n <= 16` bits at `bitOffset`, zero-padded past `end` (checked after).
        func peek(_ n: Int) -> Int {
            var word: UInt32 = 0
            let byte = bitOffset >> 3
            for i in 0..<4 where byte + i < available {
                word |= UInt32(input[start + byte + i]) << UInt32(8 * i)
            }
            return Int((word >> UInt32(bitOffset & 7)) & ((1 << UInt32(n)) - 1))
        }
        let accuracyLog = peek(4) + 5
        bitOffset = 4
        guard accuracyLog <= maxAccuracyLog else { throw ZstdDecoder.corrupt("FSE accuracy log \(accuracyLog) too large") }

        var remaining = (1 << accuracyLog) + 1
        var threshold = 1 << accuracyLog
        var nbBits = accuracyLog + 1
        var probabilities: [Int] = []
        var previousZero = false
        while remaining > 1, probabilities.count <= maxSymbol {
            if previousZero {
                var repeatCount = 0
                while true {
                    let flag = peek(2)
                    bitOffset += 2
                    repeatCount += flag
                    guard flag == 3 else { break }
                    guard bitOffset <= available * 8 else { throw ZstdDecoder.corrupt("FSE description truncated") }
                }
                guard probabilities.count + repeatCount <= maxSymbol else {
                    throw ZstdDecoder.corrupt("FSE description has too many symbols")
                }
                probabilities.append(contentsOf: repeatElement(0, count: repeatCount))
            }
            let maxValue = (2 * threshold - 1) - remaining
            var count: Int
            let low = peek(nbBits - 1)
            if low < maxValue {
                count = low
                bitOffset += nbBits - 1
            } else {
                count = peek(nbBits)
                if count >= threshold { count -= maxValue }
                bitOffset += nbBits
            }
            count -= 1
            remaining -= abs(count)
            probabilities.append(count)
            previousZero = count == 0
            guard remaining >= 1 else { throw ZstdDecoder.corrupt("FSE probabilities overflow") }
            while remaining < threshold {
                nbBits -= 1
                threshold >>= 1
            }
            guard bitOffset <= available * 8 else { throw ZstdDecoder.corrupt("FSE description truncated") }
        }
        guard remaining == 1 else { throw ZstdDecoder.corrupt("FSE probabilities don't sum to the table size") }
        let table = try build(probabilities: probabilities, accuracyLog: accuracyLog)
        return (table, (bitOffset + 7) >> 3)
    }
}

// MARK: - Sequence code tables

private enum SequenceCodes {
    static let literalBase: [UInt32] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
        8192, 16384, 32768, 65536,
    ]
    static let literalBits: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
        13, 14, 15, 16,
    ]
    static let matchBase: [UInt32] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
        19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
        35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
        4099, 8195, 16387, 32771, 65539,
    ]
    static let matchBits: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
        12, 13, 14, 15, 16,
    ]

    static let literalDefault: [Int] = [
        4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
        -1, -1, -1, -1,
    ]
    static let matchDefault: [Int] = [
        1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1,
    ]
    static let offsetDefault: [Int] = [
        1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
    ]

    // The predefined distributions are valid by construction, so these always
    // succeed; keeping the `Result` lets a failure surface as a decode error.
    static let literalTable = Result { try FSETable.build(probabilities: literalDefault, accuracyLog: 6) }
    static let matchTable = Result { try FSETable.build(probabilities: matchDefault, accuracyLog: 6) }
    static let offsetTable = Result { try FSETable.build(probabilities: offsetDefault, accuracyLog: 5) }
}

// MARK: - Stream decoder

private struct ZstdStream {
    let input: UnsafePointer<UInt8>?
    let inputCount: Int
    let output: UnsafeMutablePointer<UInt8>?
    let capacity: Int
    let verifyChecksum: Bool
    var position = 0

    // Per-frame state.
    var frameStart = 0
    var repeats: (Int, Int, Int) = (1, 4, 8)
    /// Huffman decode table (`symbol | nbBits << 8`, indexed by `maxBits` bits).
    var huffman: [UInt16] = []
    var huffmanBits = 0
    var literalTable: FSETable?
    var offsetTable: FSETable?
    var matchTable: FSETable?

    var literals = [UInt8](repeating: 0, count: ZstdDecoder.maxBlockSize)

    init(input: UnsafeRawBufferPointer, output: UnsafeMutableRawBufferPointer, verifyChecksum: Bool) {
        self.input = input.baseAddress?.assumingMemoryBound(to: UInt8.self)
        inputCount = input.count
        self.output = output.baseAddress?.assumingMemoryBound(to: UInt8.self)
        capacity = output.count
        self.verifyChecksum = verifyChecksum
    }

    private func corrupt(_ message: String) -> MIQError { ZstdDecoder.corrupt(message) }

    private func read32(_ i: Int) -> UInt32 {
        UInt32(littleEndian: UnsafeRawPointer(input! + i).loadUnaligned(as: UInt32.self))
    }

    private func readLE(_ i: Int, bytes: Int) -> UInt64 {
        var value: UInt64 = 0
        for k in 0..<bytes { value |= UInt64(input![i + k]) << UInt64(8 * k) }
        return value
    }

    private func requireOutput(_ n: Int) throws {
        guard n <= capacity - position else {
            throw MIQError.malformedFile("Zstandard data decodes to more than the expected \(capacity) bytes")
        }
    }

    mutating func run() throws -> Int {
        guard inputCount > 0, input != nil else { throw corrupt("empty input") }
        var ip = 0
        while ip < inputCount {
            guard inputCount - ip >= 4 else { throw MIQError.truncatedData }
            let magic = read32(ip)
            if magic & ZstdDecoder.skippableMagicMask == ZstdDecoder.skippableMagic {
                guard inputCount - ip >= 8 else { throw MIQError.truncatedData }
                let size = Int(read32(ip + 4))
                ip += 8
                guard size <= inputCount - ip else { throw MIQError.truncatedData }
                ip += size
                continue
            }
            guard magic == ZstdDecoder.frameMagic else { throw corrupt("bad frame magic") }
            ip = try decodeFrame(at: ip + 4)
        }
        return position
    }

    // MARK: Frames and blocks

    private mutating func decodeFrame(at start: Int) throws -> Int {
        var ip = start
        guard ip < inputCount else { throw MIQError.truncatedData }
        let descriptor = input![ip]
        ip += 1
        let contentSizeFlag = Int(descriptor >> 6)
        let singleSegment = descriptor & 0x20 != 0
        guard descriptor & 0x08 == 0 else { throw corrupt("reserved frame header bit set") }
        let hasChecksum = descriptor & 0x04 != 0
        let dictionaryBytes = [0, 1, 2, 4][Int(descriptor & 3)]
        if !singleSegment {
            guard ip < inputCount else { throw MIQError.truncatedData }
            ip += 1 // Window descriptor: matches are bounded by the frame start instead.
        }
        guard inputCount - ip >= dictionaryBytes else { throw MIQError.truncatedData }
        if dictionaryBytes > 0, readLE(ip, bytes: dictionaryBytes) != 0 {
            throw MIQError.unsupportedFeature("Zstandard data compressed with a dictionary isn't supported")
        }
        ip += dictionaryBytes
        let sizeBytes: Int
        if contentSizeFlag == 0 {
            sizeBytes = singleSegment ? 1 : 0
        } else {
            sizeBytes = [0, 2, 4, 8][contentSizeFlag]
        }
        guard inputCount - ip >= sizeBytes else { throw MIQError.truncatedData }
        var contentSize: UInt64?
        if sizeBytes > 0 {
            contentSize = readLE(ip, bytes: sizeBytes) + (sizeBytes == 2 ? 256 : 0)
        }
        ip += sizeBytes
        if let contentSize, contentSize > UInt64(capacity - position) {
            throw MIQError.malformedFile("Zstandard frame declares \(contentSize) bytes, more than the expected \(capacity)")
        }

        frameStart = position
        repeats = (1, 4, 8)
        huffman = []
        huffmanBits = 0
        literalTable = nil
        offsetTable = nil
        matchTable = nil

        while true {
            try Task.checkCancellation()
            guard inputCount - ip >= 3 else { throw MIQError.truncatedData }
            let header = Int(readLE(ip, bytes: 3))
            ip += 3
            let isLast = header & 1 != 0
            let size = header >> 3
            switch (header >> 1) & 3 {
            case 0:
                guard size <= ZstdDecoder.maxBlockSize else { throw corrupt("raw block too large") }
                guard size <= inputCount - ip else { throw MIQError.truncatedData }
                try requireOutput(size)
                if size > 0 { (output! + position).update(from: input! + ip, count: size) }
                position += size
                ip += size
            case 1:
                guard size <= ZstdDecoder.maxBlockSize else { throw corrupt("RLE block too large") }
                guard ip < inputCount else { throw MIQError.truncatedData }
                try requireOutput(size)
                if size > 0 { (output! + position).update(repeating: input![ip], count: size) }
                position += size
                ip += 1
            case 2:
                guard size <= ZstdDecoder.maxBlockSize else { throw corrupt("compressed block too large") }
                guard size <= inputCount - ip else { throw MIQError.truncatedData }
                let blockStart = position
                try decodeCompressedBlock(start: ip, end: ip + size)
                guard position - blockStart <= ZstdDecoder.maxBlockSize else {
                    throw corrupt("block decodes to more than 128 KiB")
                }
                ip += size
            default:
                throw corrupt("reserved block type")
            }
            if isLast { break }
        }

        if let contentSize, UInt64(position - frameStart) != contentSize {
            throw corrupt("frame content size mismatch")
        }
        if hasChecksum {
            guard inputCount - ip >= 4 else { throw MIQError.truncatedData }
            let stored = read32(ip)
            ip += 4
            if verifyChecksum {
                let hash = XXHash64.hash(UnsafeRawBufferPointer(
                    start: output.map { UnsafeRawPointer($0 + frameStart) }, count: position - frameStart))
                guard UInt32(truncatingIfNeeded: hash) == stored else { throw corrupt("content checksum mismatch") }
            }
        }
        return ip
    }

    private mutating func decodeCompressedBlock(start: Int, end: Int) throws {
        var ip = start
        let literalCount: Int
        (literalCount, ip) = try decodeLiterals(start: ip, end: end)

        guard ip < end else { throw MIQError.truncatedData }
        let b0 = Int(input![ip])
        ip += 1
        var sequenceCount = 0
        if b0 < 128 {
            sequenceCount = b0
        } else if b0 < 255 {
            guard ip < end else { throw MIQError.truncatedData }
            sequenceCount = ((b0 - 128) << 8) + Int(input![ip])
            ip += 1
        } else {
            guard end - ip >= 2 else { throw MIQError.truncatedData }
            sequenceCount = Int(input![ip]) + (Int(input![ip + 1]) << 8) + 0x7F00
            ip += 2
        }
        if sequenceCount == 0 {
            guard ip == end else { throw corrupt("trailing bytes after an empty sequences section") }
            try emitLiterals(from: 0, count: literalCount)
            return
        }

        guard ip < end else { throw MIQError.truncatedData }
        let modes = input![ip]
        ip += 1
        guard modes & 3 == 0 else { throw corrupt("reserved sequence mode bits set") }
        let ll = try sequenceTable(mode: Int(modes >> 6), at: &ip, end: end, previous: literalTable,
                                   predefined: SequenceCodes.literalTable, maxLog: 9, maxSymbol: 35)
        let of = try sequenceTable(mode: Int((modes >> 4) & 3), at: &ip, end: end, previous: offsetTable,
                                   predefined: SequenceCodes.offsetTable, maxLog: 8, maxSymbol: 31)
        let ml = try sequenceTable(mode: Int((modes >> 2) & 3), at: &ip, end: end, previous: matchTable,
                                   predefined: SequenceCodes.matchTable, maxLog: 9, maxSymbol: 52)
        literalTable = ll
        offsetTable = of
        matchTable = ml

        try executeSequences(count: sequenceCount, bitstreamStart: ip, end: end,
                             literalCount: literalCount, ll: ll, of: of, ml: ml)
    }

    private func sequenceTable(mode: Int, at ip: inout Int, end: Int, previous: FSETable?,
                               predefined: Result<FSETable, any Error>, maxLog: Int,
                               maxSymbol: Int) throws -> FSETable {
        switch mode {
        case 0:
            return try predefined.get()
        case 1:
            guard ip < end else { throw MIQError.truncatedData }
            let symbol = input![ip]
            ip += 1
            guard Int(symbol) <= maxSymbol else { throw corrupt("RLE sequence symbol out of range") }
            return .rle(symbol)
        case 2:
            let (table, used) = try FSETable.read(input!, start: ip, end: end, maxAccuracyLog: maxLog, maxSymbol: maxSymbol)
            guard used <= end - ip else { throw MIQError.truncatedData }
            ip += used
            return table
        default:
            guard let previous else { throw corrupt("repeat sequence table with no previous table") }
            return previous
        }
    }

    private mutating func emitLiterals(from offset: Int, count: Int) throws {
        guard count > 0 else { return }
        try requireOutput(count)
        literals.withUnsafeBufferPointer { lit in
            (output! + position).update(from: lit.baseAddress! + offset, count: count)
        }
        position += count
    }

    /// Mutable state threaded through the sequence-execution loop.
    private struct SequenceCursor {
        var reader: BackwardBitReader
        var llState: Int
        var ofState: Int
        var mlState: Int
        var literalPosition = 0
        var rep1: Int
        var rep2: Int
        var rep3: Int
        var position: Int
    }

    /// Fixed bounds for one block's sequence execution.
    private struct SequenceLimits {
        let count: Int
        let literalCount: Int
        let frameStart: Int
        let capacity: Int
        let output: UnsafeMutablePointer<UInt8>?
    }

    private mutating func executeSequences(count: Int, bitstreamStart: Int, end: Int, literalCount: Int,
                                           ll: FSETable, of: FSETable, ml: FSETable) throws {
        var reader = try BackwardBitReader(input! + bitstreamStart, count: end - bitstreamStart)
        let llState = Int(reader.read(ll.accuracyLog))
        let ofState = Int(reader.read(of.accuracyLog))
        let mlState = Int(reader.read(ml.accuracyLog))
        guard reader.position >= 0 else { throw MIQError.truncatedData }

        let (rep1, rep2, rep3) = repeats
        var cursor = SequenceCursor(reader: reader, llState: llState, ofState: ofState, mlState: mlState,
                                    rep1: rep1, rep2: rep2, rep3: rep3, position: position)
        let limits = SequenceLimits(count: count, literalCount: literalCount, frameStart: frameStart,
                                    capacity: capacity, output: output)

        try literals.withUnsafeBufferPointer { lit in
            try ll.entries.withUnsafeBufferPointer { llT in
                try Self.runSequences(&cursor, limits: limits, lit: lit, llT: llT, of: of, ml: ml)
            }
        }
        position = cursor.position
        repeats = (cursor.rep1, cursor.rep2, cursor.rep3)
        guard cursor.reader.position == 0 else { throw ZstdDecoder.corrupt("sequence bitstream not fully consumed") }
        try emitLiterals(from: cursor.literalPosition, count: literalCount - cursor.literalPosition)
    }

    /// The hot loop of `executeSequences`: decodes each sequence's codes, updates
    /// the repeat offsets, and copies its literals and match into the output.
    @inline(__always)
    private static func runSequences(_ cursor: inout SequenceCursor, limits: SequenceLimits,
                                     lit: UnsafeBufferPointer<UInt8>, llT: UnsafeBufferPointer<UInt32>,
                                     of: FSETable, ml: FSETable) throws {
        try of.entries.withUnsafeBufferPointer { ofT in
            try ml.entries.withUnsafeBufferPointer { mlT in
                for i in 0..<limits.count {
                    let llEntry = llT[cursor.llState]
                    let ofEntry = ofT[cursor.ofState]
                    let mlEntry = mlT[cursor.mlState]
                    let ofCode = FSETable.symbol(ofEntry)
                    let mlCode = FSETable.symbol(mlEntry)
                    let llCode = FSETable.symbol(llEntry)

                    let offsetValue = (1 << ofCode) + Int(cursor.reader.read(ofCode))
                    let matchLength = Int(SequenceCodes.matchBase[mlCode])
                        + Int(cursor.reader.read(Int(SequenceCodes.matchBits[mlCode])))
                    let literalLength = Int(SequenceCodes.literalBase[llCode])
                        + Int(cursor.reader.read(Int(SequenceCodes.literalBits[llCode])))

                    var offset: Int
                    if offsetValue > 3 {
                        offset = offsetValue - 3
                        cursor.rep3 = cursor.rep2
                        cursor.rep2 = cursor.rep1
                        cursor.rep1 = offset
                    } else {
                        let index = offsetValue - 1 + (literalLength == 0 ? 1 : 0)
                        switch index {
                        case 0:
                            offset = cursor.rep1
                        case 1:
                            offset = cursor.rep2
                            cursor.rep2 = cursor.rep1
                            cursor.rep1 = offset
                        case 2:
                            offset = cursor.rep3
                            cursor.rep3 = cursor.rep2
                            cursor.rep2 = cursor.rep1
                            cursor.rep1 = offset
                        default:
                            offset = cursor.rep1 - 1
                            cursor.rep3 = cursor.rep2
                            cursor.rep2 = cursor.rep1
                            cursor.rep1 = offset
                        }
                    }

                    if i != limits.count - 1 {
                        cursor.llState = FSETable.base(llEntry) + Int(cursor.reader.read(FSETable.bitCount(llEntry)))
                        cursor.mlState = FSETable.base(mlEntry) + Int(cursor.reader.read(FSETable.bitCount(mlEntry)))
                        cursor.ofState = FSETable.base(ofEntry) + Int(cursor.reader.read(FSETable.bitCount(ofEntry)))
                    }
                    guard cursor.reader.position >= 0 else { throw MIQError.truncatedData }

                    guard literalLength <= limits.literalCount - cursor.literalPosition else {
                        throw ZstdDecoder.corrupt("sequence uses more literals than decoded")
                    }
                    guard literalLength + matchLength <= limits.capacity - cursor.position else {
                        throw MIQError.malformedFile("Zstandard data decodes to more than the expected \(limits.capacity) bytes")
                    }
                    guard offset > 0, offset <= cursor.position + literalLength - limits.frameStart else {
                        throw ZstdDecoder.corrupt("match offset reaches before the frame")
                    }
                    let out = limits.output!
                    if literalLength > 0 {
                        (out + cursor.position).update(from: lit.baseAddress! + cursor.literalPosition, count: literalLength)
                        cursor.position += literalLength
                        cursor.literalPosition += literalLength
                    }
                    LZ4Decoder.copyMatch(out, at: cursor.position, offset: offset, length: matchLength)
                    cursor.position += matchLength
                }
            }
        }
    }

    // MARK: Literals

    /// Decodes the literals section into `literals`; returns its size and the
    /// index just past the section.
    private mutating func decodeLiterals(start: Int, end: Int) throws -> (Int, Int) {
        guard start < end else { throw MIQError.truncatedData }
        let b0 = Int(input![start])
        let type = b0 & 3
        let sizeFormat = (b0 >> 2) & 3
        if type < 2 {
            let headerSize: Int
            let regenerated: Int
            switch sizeFormat {
            case 0, 2:
                headerSize = 1
                regenerated = b0 >> 3
            case 1:
                guard end - start >= 2 else { throw MIQError.truncatedData }
                headerSize = 2
                regenerated = (b0 >> 4) + (Int(input![start + 1]) << 4)
            default:
                guard end - start >= 3 else { throw MIQError.truncatedData }
                headerSize = 3
                regenerated = (b0 >> 4) + (Int(input![start + 1]) << 4) + (Int(input![start + 2]) << 12)
            }
            guard regenerated <= ZstdDecoder.maxBlockSize else { throw corrupt("literals section too large") }
            let ip = start + headerSize
            if type == 0 {
                guard regenerated <= end - ip else { throw MIQError.truncatedData }
                if regenerated > 0 {
                    literals.withUnsafeMutableBufferPointer { lit in
                        lit.baseAddress!.update(from: input! + ip, count: regenerated)
                    }
                }
                return (regenerated, ip + regenerated)
            }
            guard ip < end else { throw MIQError.truncatedData }
            let byte = input![ip]
            literals.withUnsafeMutableBufferPointer { lit in
                lit.baseAddress!.update(repeating: byte, count: regenerated)
            }
            return (regenerated, ip + 1)
        }

        let headerSize: Int
        let sizeBits: Int
        let streams: Int
        switch sizeFormat {
        case 0: (headerSize, sizeBits, streams) = (3, 10, 1)
        case 1: (headerSize, sizeBits, streams) = (3, 10, 4)
        case 2: (headerSize, sizeBits, streams) = (4, 14, 4)
        default: (headerSize, sizeBits, streams) = (5, 18, 4)
        }
        guard end - start >= headerSize else { throw MIQError.truncatedData }
        let header = readLE(start, bytes: headerSize)
        let mask = (UInt64(1) << UInt64(sizeBits)) - 1
        let regenerated = Int((header >> 4) & mask)
        let compressed = Int((header >> UInt64(4 + sizeBits)) & mask)
        guard regenerated <= ZstdDecoder.maxBlockSize else { throw corrupt("literals section too large") }
        var ip = start + headerSize
        guard compressed <= end - ip else { throw MIQError.truncatedData }
        let sectionEnd = ip + compressed
        if type == 2 {
            ip = try readHuffmanTable(start: ip, end: sectionEnd)
        } else {
            guard huffmanBits > 0 else { throw corrupt("treeless literals with no previous Huffman table") }
        }
        if streams == 1 {
            try decodeHuffmanStream(start: ip, end: sectionEnd, into: 0, count: regenerated)
        } else {
            guard sectionEnd - ip >= 6 else { throw MIQError.truncatedData }
            let s1 = Int(readLE(ip, bytes: 2))
            let s2 = Int(readLE(ip + 2, bytes: 2))
            let s3 = Int(readLE(ip + 4, bytes: 2))
            ip += 6
            guard s1 + s2 + s3 <= sectionEnd - ip else { throw MIQError.truncatedData }
            let segment = (regenerated + 3) / 4
            guard regenerated >= 3 * segment else { throw corrupt("four-stream literals too short") }
            var p = ip
            for (k, size) in [s1, s2, s3, sectionEnd - ip - s1 - s2 - s3].enumerated() {
                let n = k == 3 ? regenerated - 3 * segment : segment
                try decodeHuffmanStream(start: p, end: p + size, into: k * segment, count: n)
                p += size
            }
        }
        return (regenerated, sectionEnd)
    }

    private mutating func decodeHuffmanStream(start: Int, end: Int, into offset: Int, count: Int) throws {
        var reader = try BackwardBitReader(input! + start, count: end - start)
        let maxBits = huffmanBits
        let huffman = self.huffman
        huffman.withUnsafeBufferPointer { table in
            literals.withUnsafeMutableBufferPointer { lit in
                for k in 0..<count {
                    let entry = table[Int(reader.peek(maxBits))]
                    lit[offset + k] = UInt8(truncatingIfNeeded: entry)
                    reader.position -= Int(entry >> 8)
                }
            }
        }
        guard reader.position == 0 else { throw corrupt("Huffman stream not fully consumed") }
    }

    /// Parses a Huffman tree description (§4.2.1) into `huffman`.
    private mutating func readHuffmanTable(start: Int, end: Int) throws -> Int {
        guard start < end else { throw MIQError.truncatedData }
        let headerByte = Int(input![start])
        var ip = start + 1
        var weights: [UInt8] = []
        if headerByte < 128 {
            guard headerByte > 0, headerByte <= end - ip else { throw MIQError.truncatedData }
            let streamEnd = ip + headerByte
            let (table, used) = try FSETable.read(input!, start: ip, end: streamEnd, maxAccuracyLog: 6, maxSymbol: 255)
            guard used < headerByte else { throw MIQError.truncatedData }
            var reader = try BackwardBitReader(input! + ip + used, count: headerByte - used)
            var state1 = Int(reader.read(table.accuracyLog))
            var state2 = Int(reader.read(table.accuracyLog))
            guard reader.position >= 0 else { throw MIQError.truncatedData }
            let t = table.entries
            while true {
                guard weights.count < 255 else { throw corrupt("too many Huffman weights") }
                var e = t[state1]
                weights.append(UInt8(FSETable.symbol(e)))
                state1 = FSETable.base(e) + Int(reader.read(FSETable.bitCount(e)))
                if reader.position < 0 {
                    weights.append(UInt8(FSETable.symbol(t[state2])))
                    break
                }
                guard weights.count < 255 else { throw corrupt("too many Huffman weights") }
                e = t[state2]
                weights.append(UInt8(FSETable.symbol(e)))
                state2 = FSETable.base(e) + Int(reader.read(FSETable.bitCount(e)))
                if reader.position < 0 {
                    weights.append(UInt8(FSETable.symbol(t[state1])))
                    break
                }
            }
            ip = streamEnd
        } else {
            let count = headerByte - 127
            let bytes = (count + 1) / 2
            guard bytes <= end - ip else { throw MIQError.truncatedData }
            for i in 0..<count {
                let byte = input![ip + i / 2]
                weights.append(i % 2 == 0 ? byte >> 4 : byte & 15)
            }
            ip += bytes
        }
        guard weights.count <= 255 else { throw corrupt("too many Huffman weights") }

        var sum = 0
        for w in weights {
            guard w <= 11 else { throw corrupt("Huffman weight too large") }
            if w > 0 { sum += 1 << (Int(w) - 1) }
        }
        guard sum > 0 else { throw corrupt("Huffman weights are all zero") }
        let maxBits = Int.bitWidth - sum.leadingZeroBitCount // highbit(sum) + 1
        guard maxBits <= 11 else { throw corrupt("Huffman code too long") }
        let rest = (1 << maxBits) - sum
        guard rest > 0, rest & (rest - 1) == 0 else { throw corrupt("Huffman weights don't form a complete code") }
        weights.append(UInt8(Int.bitWidth - rest.leadingZeroBitCount)) // log2(rest) + 1

        var table = [UInt16](repeating: 0, count: 1 << maxBits)
        var next = 0
        for weight in 1...maxBits {
            let span = 1 << (weight - 1)
            let bits = UInt16(maxBits + 1 - weight) << 8
            for (symbol, w) in weights.enumerated() where Int(w) == weight {
                guard next + span <= table.count else { throw corrupt("Huffman table overfull") }
                for k in next..<(next + span) { table[k] = UInt16(symbol) | bits }
                next += span
            }
        }
        guard next == table.count else { throw corrupt("Huffman table incomplete") }
        huffman = table
        huffmanBits = maxBits
        return ip
    }
}
