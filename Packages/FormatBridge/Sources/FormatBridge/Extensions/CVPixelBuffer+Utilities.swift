import CoreVideo

extension CVPixelBuffer {
    var width: Int {
        CVPixelBufferGetWidth(self)
    }

    var height: Int {
        CVPixelBufferGetHeight(self)
    }

    var pixelFormatType: OSType {
        CVPixelBufferGetPixelFormatType(self)
    }

    var bytesPerRow: Int {
        CVPixelBufferGetBytesPerRow(self)
    }
}
