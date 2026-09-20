import Foundation
import zlib

enum Gzip {
    static func compress(_ input: Data) -> Data {
        guard !input.isEmpty else { return input }
        var stream = z_stream()
        let initStatus = input.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return Z_ERRNO }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)
            return deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                                 ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        }
        guard initStatus == Z_OK else { return input }
        defer { deflateEnd(&stream) }
        var output = Data()
        var buffer = [Bytef](repeating: 0, count: 16_384)
        var status: Int32
        repeat {
            status = buffer.withUnsafeMutableBytes { raw -> Int32 in
                stream.next_out = raw.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(raw.count)
                return deflate(&stream, Z_FINISH)
            }
            let produced = buffer.count - Int(stream.avail_out)
            if produced > 0 { output.append(buffer, count: produced) }
        } while status == Z_OK
        return status == Z_STREAM_END ? output : input
    }
}
