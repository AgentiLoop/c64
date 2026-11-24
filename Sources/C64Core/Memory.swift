/// A fixed-size block of bytes (RAM or ROM) read and written every emulated cycle. It is a plain
/// pointer, so accesses don't retain an array buffer or check copy-on-write; copies of the struct
/// share the same bytes. The owner frees it with `deallocate()`.
public struct Memory: RandomAccessCollection, MutableCollection {
    let base: UnsafeMutablePointer<UInt8>
    public let count: Int

    init(count: Int, repeating value: UInt8 = 0) {
        base = .allocate(capacity: count)
        base.initialize(repeating: value, count: count)
        self.count = count
    }

    init(_ bytes: [UInt8]) {
        self.init(count: bytes.count)
        for (i, b) in bytes.enumerated() { base[i] = b }
    }

    func deallocate() { base.deallocate() }

    public var startIndex: Int { 0 }
    public var endIndex: Int { count }

    public subscript(i: Int) -> UInt8 {
        @inline(__always) get { base[i] }
        @inline(__always) nonmutating set { base[i] = newValue }
    }

    /// Copies `bytes` over the same number of bytes starting at `range.lowerBound`.
    public func replaceSubrange(_ range: Range<Int>, with bytes: [UInt8]) {
        for (i, b) in bytes.enumerated() where range.lowerBound + i < count { base[range.lowerBound + i] = b }
    }
}
