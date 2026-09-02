import Foundation

/// Host-side mirror of `ClassifierHead.cpp` LFMC parsing and argmax for unit tests.
/// Production inference uses the native C++ helper through the LFM llama bridge.
enum LfmcClassifier {
    struct Head {
        let hiddenSize: Int
        let weight: [Float]
        let bias: [Float]
        let labels: [String]

        func classify(_ embedding: [Float]) -> String? {
            guard embedding.count == hiddenSize else { return nil }
            var normalized = embedding
            l2Normalize(&normalized)
            var bestIndex = 0
            var bestScore = -Float.infinity
            for label in bias.indices {
                var score = bias[label]
                let offset = label * hiddenSize
                for dim in 0..<hiddenSize {
                    score += weight[offset + dim] * normalized[dim]
                }
                if score > bestScore {
                    bestScore = score
                    bestIndex = label
                }
            }
            return labels[bestIndex]
        }
    }

    static func load(_ bytes: Data, expectedHiddenSize: Int = -1) -> Head? {
        guard bytes.count >= 12 else { return nil }
        let magic = Data([UInt8(ascii: "L"), UInt8(ascii: "F"), UInt8(ascii: "M"), UInt8(ascii: "C")])
        guard bytes.prefix(4) == magic else { return nil }

        let numLabels = Int(readUInt32LE(bytes, offset: 4))
        let hiddenSize = Int(readUInt32LE(bytes, offset: 8))
        guard numLabels > 0, hiddenSize > 0 else { return nil }
        if expectedHiddenSize > 0, hiddenSize != expectedHiddenSize { return nil }

        let expectedBytes = 12 + (numLabels * hiddenSize * 4) + (numLabels * 4)
        guard bytes.count == expectedBytes else { return nil }

        var weight = [Float](repeating: 0, count: numLabels * hiddenSize)
        var bias = [Float](repeating: 0, count: numLabels)
        var cursor = 12
        for index in weight.indices {
            weight[index] = readFloat32LE(bytes, offset: cursor)
            cursor += 4
        }
        for index in bias.indices {
            bias[index] = readFloat32LE(bytes, offset: cursor)
            cursor += 4
        }
        return Head(
            hiddenSize: hiddenSize,
            weight: weight,
            bias: bias,
            labels: defaultLabels(numLabels: numLabels)
        )
    }

    private static func defaultLabels(numLabels: Int) -> [String] {
        if numLabels == 2 {
            return ["playback:pause", "no_match:"]
        }
        return (0..<numLabels).map { "label:\($0)" }
    }

    private static func l2Normalize(_ vector: inout [Float], epsilon: Float = 1e-6) {
        var sumSquares = 0.0
        for value in vector {
            sumSquares += Double(value) * Double(value)
        }
        let scale = Float(1.0 / max(sqrt(sumSquares), Double(epsilon)))
        for index in vector.indices {
            vector[index] *= scale
        }
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    private static func readFloat32LE(_ data: Data, offset: Int) -> Float {
        let bits = readUInt32LE(data, offset: offset)
        return Float(bitPattern: bits)
    }
}
