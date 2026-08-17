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
            let inputUrl = URL(fileURLWithPath: media.filePath ?? "")

            // Extract video metadata before compression
            var mediaWithMetadata = media
            if let filePath = media.filePath {
                let fileUrl = URL(fileURLWithPath: filePath)
                mediaWithMetadata.exifMetadata = EXIFMetadataHelper.extractVideoMetadata(from: fileUrl)
            }

            let fileNameWithoutExtension = self.removeExtension(fileName: media.name)
            let fileManager = FileManager.default
            let documentsUrl = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let compressedName = "compressed_\(fileNameWithoutExtension).mp4"
            let outputUrl = documentsUrl.appendingPathComponent(compressedName)
            MediaCompressor.compressVideo(inputURL: inputUrl, outputURL: outputUrl) { url, error in
                if error == nil, url != nil {
                    try? FileManager.default.removeItem(at: inputUrl)
                    try? FileManager.default.moveItem(at: outputUrl, to: inputUrl)
                    var tempMedia = mediaWithMetadata
                    tempMedia.filePath = inputUrl.path
                    tempMedia.mimeType = "video/mp4"
                    self.uploadFile(tempMedia, baseS3URL, safeIndexPath, safeIndex, completion)
                } else {
                    debugPrint("Error in compression>>\(String(describing: error))")
                    self.uploadFile(mediaWithMetadata, baseS3URL, safeIndexPath, safeIndex, completion)
                }
            }

        } else if (media.mimeType ?? "").hasPrefix("image") {
            // Extract EXIF metadata before compression
            var mediaWithEXIF = media
            if let filePath = media.filePath {
                let fileUrl = URL(fileURLWithPath: filePath)
                mediaWithEXIF.exifMetadata = EXIFMetadataHelper.extractEXIF(from: fileUrl)
            }

            // Pass extracted EXIF so compressImage skips a redundant file open
            MediaCompressor.compressImage(fileName: media.name, existingMetadata: mediaWithEXIF.exifMetadata) {
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
    public func compressMediaFile(media: SSMedia, completion: @escaping (SSMedia) -> Void) {
        if (media.mimeType ?? "").contains("video") {
            DispatchQueue.global(qos: .userInitiated).async {
                var mediaWithMetadata = media
                if let filePath = media.filePath {
                    mediaWithMetadata.exifMetadata = EXIFMetadataHelper.extractVideoMetadata(from: URL(fileURLWithPath: filePath))
                }
                let inputUrl = URL(fileURLWithPath: media.filePath ?? "")
                let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let outputUrl = documentsUrl.appendingPathComponent("compressed_\(self.removeExtension(fileName: media.name)).mp4")
                MediaCompressor.compressVideo(inputURL: inputUrl, outputURL: outputUrl) { url, error in
                    DispatchQueue.main.async {
                        if error == nil, url != nil {
                            try? FileManager.default.removeItem(at: inputUrl)
                            try? FileManager.default.moveItem(at: outputUrl, to: inputUrl)
                            var tempMedia = mediaWithMetadata
                            tempMedia.filePath = inputUrl.path
                            tempMedia.mimeType = "video/mp4"
                            completion(tempMedia)
                        } else {
                            completion(mediaWithMetadata)
                        }
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
                MediaCompressor.compressImage(fileName: media.name, existingMetadata: mediaWithEXIF.exifMetadata) {
                    completion(mediaWithEXIF)
                }
            }
        } else {
            DispatchQueue.main.async { completion(media) }
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

