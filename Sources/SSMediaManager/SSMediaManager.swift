//
//  SSMediaManager.swift
//  SSMediaManager
//
//  Created by Apple on 21/06/22.
//

import Foundation

public class SSMediaManager{
    nonisolated(unsafe) public static let shared = SSMediaManager()
    
    public var onNetworkStatusChange: ((Bool) -> Void)?
    
    private init(){
    }
    
    func networkStatusChanged(isConnected: Bool) {
        DispatchQueue.main.async {
            self.onNetworkStatusChange?(isConnected)
        }
    }
    
    public func cancelAllUploads() {
        APIManager.shared.cancelAllRequests()
    }
    
    fileprivate func uploadFile(_ media: SSMedia, _ baseS3URL: String, _ indexPath: IndexPath, _ index: Int, _ completion: @escaping UploadCompletion) {
        APIManager.shared.getUploadUrl(media: media, baseS3URL: baseS3URL, indexPath: indexPath, index: index) { json, data, response, error, indexPath, index in
            var mediaWithS3 = media
            if let s3url = json?["s3URL"] as? String {
                mediaWithS3.serverUrl = s3url
            }
            if let uploadUrl = json?["uploadURL"] as? String {
                APIManager.shared.uploadMediaWith(uploadUrl: uploadUrl, media: mediaWithS3, indexPath: indexPath, index: index, json: json, completion: completion)
            } else {
                completion(nil, nil, nil, error, indexPath, index)
            }
        }
    }

    public func uploadFileWith(media: SSMedia, baseS3URL: String, indexPath: IndexPath? = nil, index: Int? = 0, completion: @escaping UploadCompletion) {
        // Resolve optionals once here so every internal call site is non-optional
        let safeIndexPath = indexPath ?? IndexPath(row: 0, section: 0)
        let safeIndex = index ?? 0

        if (media.mimeType ?? "").contains("video") {
            compressMediaFile(media: media) { preparedMedia, success in
                guard success else {
                    completion(nil, nil, nil, NSError(
                        domain: "SSMediaManager", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Upload failed: no usable local video file"]
                    ), safeIndexPath, safeIndex)
                    return
                }
                self.uploadFile(preparedMedia, baseS3URL, safeIndexPath, safeIndex, completion)
            }

        } else if (media.mimeType ?? "").hasPrefix("image") {
            // Extract EXIF metadata before compression
            var mediaWithEXIF = media
            if let filePath = media.filePath {
                let fileUrl = URL(fileURLWithPath: filePath)
                mediaWithEXIF.exifMetadata = EXIFMetadataHelper.extractEXIF(from: fileUrl)
            }

            // Pass extracted EXIF so compressImage skips a redundant file open
            MediaCompressor.compressImage(fileName: media.name, filePath: media.filePath, existingMetadata: mediaWithEXIF.exifMetadata) { success in
                guard success else {
                    // No valid file on disk to upload — fail loudly instead of PUTting an
                    // empty/missing file that S3 would otherwise accept silently.
                    completion(nil, nil, nil, NSError(
                        domain: "SSMediaManager", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Upload failed: compression left no valid file on disk"]
                    ), safeIndexPath, safeIndex)
                    return
                }
                self.uploadFile(mediaWithEXIF, baseS3URL, safeIndexPath, safeIndex, completion)
            }

        } else {
            self.uploadFile(media, baseS3URL, safeIndexPath, safeIndex, completion)
        }
    }
    
    // Compresses a media file in-place and returns an updated SSMedia with EXIF metadata populated.
    // For images/videos the file on disk is overwritten with the compressed version.
    // EXIF extraction and compression both run on a background queue to avoid blocking the main thread.
    // Completion is always called on the main queue.
    // completion's Bool reports whether `media`'s filePath is confirmed to hold valid,
    // upload-ready content. false means the caller must not attempt to upload this item —
    // route it to failed-upload tracking instead, the same as a failed network upload.
    public func compressMediaFile(media: SSMedia, completion: @escaping (SSMedia, Bool) -> Void) {
        if (media.mimeType ?? "").contains("video") {
            DispatchQueue.global(qos: .userInitiated).async {
                guard let filePath = media.filePath, !filePath.isEmpty else {
                    DispatchQueue.main.async { completion(media, false) }
                    return
                }
                let inputUrl = URL(fileURLWithPath: filePath)
                guard MediaCompressor.isUsableFile(at: inputUrl) else {
                    DispatchQueue.main.async { completion(media, false) }
                    return
                }
                var mediaWithMetadata = media
                mediaWithMetadata.exifMetadata = EXIFMetadataHelper.extractVideoMetadata(from: inputUrl)
                let outputUrl = MediaCompressor.stagingURL(for: inputUrl, extension: "mp4")
                MediaCompressor.compressVideo(inputURL: inputUrl, outputURL: outputUrl) { url, error in
                    defer { try? FileManager.default.removeItem(at: outputUrl) }
                    let replaced = error == nil && url != nil &&
                        MediaCompressor.replaceOriginal(at: inputUrl, with: outputUrl)
                    let originalIsUsable = MediaCompressor.isUsableFile(at: inputUrl)
                    DispatchQueue.main.async {
                        guard replaced else {
                            completion(mediaWithMetadata, originalIsUsable)
                            return
                        }
                        var tempMedia = mediaWithMetadata
                        tempMedia.filePath = inputUrl.path
                        tempMedia.mimeType = "video/mp4"
                        completion(tempMedia, true)
                    }
                }
            }
        } else if (media.mimeType ?? "").hasPrefix("image") {
            DispatchQueue.global(qos: .userInitiated).async {
                var mediaWithEXIF = media
                if let filePath = media.filePath {
                    mediaWithEXIF.exifMetadata = EXIFMetadataHelper.extractEXIF(from: URL(fileURLWithPath: filePath))
                }
                // compressImage dispatches to its own background queue; completion fires on main.
                MediaCompressor.compressImage(fileName: media.name, filePath: media.filePath, existingMetadata: mediaWithEXIF.exifMetadata) { success in
                    completion(mediaWithEXIF, success)
                }
            }
        } else {
            DispatchQueue.main.async { completion(media, true) }
        }
    }

    // Uploads a media file that has already been compressed. Skips the compression step.
    // Use in tandem with compressMediaFile to pipeline compress-then-upload-concurrently.
    public func uploadCompressedFile(media: SSMedia, baseS3URL: String, indexPath: IndexPath, index: Int, completion: @escaping UploadCompletion) {
        uploadFile(media, baseS3URL, indexPath, index, completion)
    }

    func removeExtension(fileName:String) -> String {
        var components = fileName.components(separatedBy: ".")
        if components.count > 1 { // If there is a file extension
            components.removeLast()
            return components.joined(separator: ".")
        } else {
            return fileName
        }
    }
}

