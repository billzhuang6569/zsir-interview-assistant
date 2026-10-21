import AVFoundation

public enum LivePreviewSample {
    /// A separate sample wrapper shares the pixels without changing the recording sample's attachments.
    public static func make(from source: CMSampleBuffer) -> CMSampleBuffer? {
        guard let pixel = CMSampleBufferGetImageBuffer(source),
              let format = CMSampleBufferGetFormatDescription(source) else { return nil }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(source),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &result) == noErr,
              let result,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return nil }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        return result
    }
}
