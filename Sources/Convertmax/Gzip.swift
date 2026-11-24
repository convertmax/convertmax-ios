import Foundation
import zlib

enum Gzip {
    /// Returns a gzip-encoded copy of `input`, or `nil` if the input is empty or zlib fails.
    /// Callers must not send the body with `Content-Encoding: gzip` when this returns `nil`.
    static func compress(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        var stream = z_stream()
        return input.withUnsafeBytes { raw -> Data? in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)
            let initStatus = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                                           ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard initStatus == Z_OK else { return nil }
            defer { deflateEnd(&stream) }
            var output = Data()
            var buffer = [Bytef](repeating: 0, count: 16_384)
            var status: Int32
            repeat {
                status = buffer.withUnsafeMutableBytes { out -> Int32 in
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(out.count)
                    return deflate(&stream, Z_FINISH)
                }
                let produced = buffer.count - Int(stream.avail_out)
                if produced > 0 { output.append(buffer, count: produced) }
            } while status == Z_OK
            return status == Z_STREAM_END ? output : nil
        }
    }
}
