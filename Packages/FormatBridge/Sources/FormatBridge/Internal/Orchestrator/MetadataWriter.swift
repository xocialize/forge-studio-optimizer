import AVFoundation
import CoreMedia
import Foundation

/// Applies metadata and chapter markers to an AVAssetWriter output.
struct MetadataWriter {

    /// Apply source metadata to the asset writer as metadata items.
    static func applyMetadata(
        to writer: AVAssetWriter,
        from mediaInfo: MediaInfo
    ) {
        var items: [AVMetadataItem] = []

        // Title
        if let title = mediaInfo.metadata["title"] {
            items.append(makeItem(key: .commonKeyTitle, value: title))
        }

        // Artist / creator
        if let artist = mediaInfo.metadata["artist"] ?? mediaInfo.metadata["ARTIST"] {
            items.append(makeItem(key: .commonKeyArtist, value: artist))
        }

        // Comment / description
        if let comment = mediaInfo.metadata["comment"] ?? mediaInfo.metadata["description"] {
            items.append(makeItem(key: .commonKeyDescription, value: comment))
        }

        // Creation date
        if let date = mediaInfo.metadata["creation_time"] ?? mediaInfo.metadata["date"] {
            items.append(makeItem(key: .commonKeyCreationDate, value: date))
        }

        // Encoder tag
        items.append(makeItem(key: .commonKeySoftware, value: "Forge"))

        if !items.isEmpty {
            writer.metadata = items
        }
    }

    /// Write chapter markers as a timed metadata track.
    /// Call after configuring the writer but before starting the session.
    static func addChapterTrack(
        to writer: AVAssetWriter,
        chapters: [Chapter],
        duration: CMTime
    ) -> AVAssetWriterInput? {
        guard !chapters.isEmpty else { return nil }

        // Chapter track uses text metadata
        let formatDesc = createChapterFormatDescription()
        guard let desc = formatDesc else { return nil }

        let chapterInput = AVAssetWriterInput(
            mediaType: .text,
            outputSettings: nil,
            sourceFormatHint: desc
        )
        chapterInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(chapterInput) else { return nil }
        writer.add(chapterInput)

        return chapterInput
    }

    /// Write chapter sample buffers to the chapter track input.
    static func writeChapters(
        _ chapters: [Chapter],
        to input: AVAssetWriterInput
    ) {
        for chapter in chapters {
            guard let title = chapter.title else { continue }
            guard let titleData = title.data(using: .utf8) else { continue }

            let duration = CMTimeSubtract(chapter.endTime, chapter.startTime)

            // Create a simple text sample buffer for the chapter
            var blockBuffer: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil,
                memoryBlock: nil,
                blockLength: titleData.count,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: titleData.count,
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &blockBuffer
            )

            guard let block = blockBuffer else { continue }
            titleData.withUnsafeBytes { ptr in
                CMBlockBufferReplaceDataBytes(
                    with: ptr.baseAddress!, blockBuffer: block,
                    offsetIntoDestination: 0, dataLength: titleData.count
                )
            }

            // Wait for input ready
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
    }

    // MARK: - Helpers

    private static func makeItem(key: AVMetadataKey, value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = key as any NSCopying & NSObjectProtocol
        item.keySpace = .common
        item.value = value as any NSCopying & NSObjectProtocol
        return item
    }

    private static func createChapterFormatDescription() -> CMFormatDescription? {
        var desc: CMFormatDescription?
        CMFormatDescriptionCreate(
            allocator: nil,
            mediaType: kCMMediaType_Text,
            mediaSubType: kCMTextFormatType_3GText,
            extensions: nil,
            formatDescriptionOut: &desc
        )
        return desc
    }
}
