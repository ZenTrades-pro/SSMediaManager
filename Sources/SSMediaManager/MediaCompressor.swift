//
//  MediaCompressor.swift
//  SSMediaManager
//
//  Created by Apple on 23/06/23.
//

import Foundation
import Darwin
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

var documentsUrl: URL? {
    return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
}

class MediaCompressor {
    private static var documentsUrl: URL? {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
    static func stagingURL(for original: URL, extension fileExtension: String) -> URL {
        original.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
    }

    static func isUsableFile(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }

    static func imageMIMEType(at url: URL) -> String? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let image = CGImageSourceCreateWithURL(url as CFURL, options),
              let identifier = CGImageSourceGetType(image) else { return nil }
        return UTType(identifier as String)?.preferredMIMEType
    }

    static func videoMIMEType(at url: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let header = try? file.read(upToCount: 12), header.count == 12,
              header[4..<8].elementsEqual("ftyp".utf8),
              let brand = String(bytes: header[8..<12], encoding: .ascii) else { return nil }

        switch brand {
        case "qt  ": return "video/quicktime"
        case "isom", "iso2", "iso3", "iso4", "iso5", "iso6", "mp41", "mp42", "avc1", "M4V ":
            return "video/mp4"
        default: return nil
        }
    }

    static func replaceOriginal(at original: URL, with staged: URL) -> Bool {
        guard isUsableFile(at: staged) else { return false }
        // Both paths are in the same directory, so rename atomically replaces the original.
        return Darwin.rename(staged.path, original.path) == 0
    }

    static func isPlayableVideo(at url: URL) async -> Bool {
        guard isUsableFile(at: url) else { return false }
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable) else { return false }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 32, height: 32)
            // A nonempty, playable container can still contain undecodable video samples.
            _ = try await generator.image(at: .zero)
            return true
        } catch {
            return false
        }
    }

    class func compressVideo(inputURL: URL, outputURL: URL, completion: @escaping (URL?, Error?) -> Void) {
        let asset = AVURLAsset(url: inputURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            completion(nil, NSError(domain: "VideoCompressor", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to create AVAssetExportSession"]))
            return
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        
        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                completion(outputURL, nil)
            case .failed:
                completion(nil, exportSession.error)
            case .cancelled:
                completion(nil, NSError(domain: "VideoCompressor", code: 0, userInfo: [NSLocalizedDescriptionKey: "Video compression was cancelled"]))
            @unknown default:
                // Guard against future AVAssetExportSession status values — always deliver
                // a completion so the upload chain is never permanently stalled.
                completion(nil, NSError(domain: "VideoCompressor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video compression ended with an unexpected status: \(exportSession.status.rawValue)"]))
            }
        }
    }
    
    // Locates the image on disk. The real path (media.filePath) wins when it exists; otherwise
    // fileName is searched in Caches, then Documents. Falls back to the Documents path when the
    // file is in none of them, so callers still get a URL to report a clean failure on.
    private class func resolveImageFileURL(fileName: String, filePath: String?) -> URL? {
        let fm = FileManager.default
        if let filePath, !filePath.isEmpty, fm.fileExists(atPath: filePath) {
            return URL(fileURLWithPath: filePath)
        }
        if let cachesUrl = fm.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(fileName),
           fm.fileExists(atPath: cachesUrl.path) {
            return cachesUrl
        }
        return documentsUrl?.appendingPathComponent(fileName)
    }

    // Returns the usable file and whether JPEG output replaced its original contents.
    class func compressImage(fileName: String, filePath: String? = nil, existingMetadata: [String: Any]? = nil, completion: @escaping ((fileURL: URL, wroteJPEG: Bool)?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            autoreleasepool {
                guard let fileUrl = resolveImageFileURL(fileName: fileName, filePath: filePath) else {
                    // `return` only exits this autoreleasepool closure, not the outer async block.
                    // completion() must be called here; there must be NO call after the pool closes.
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                let modeValue = UserDefaults.standard.value(forKey: "CompressionModeFloat") as? CGFloat ?? 0.5
                let compressionMode = CompressionMode(rawValue: modeValue) ?? .medium

                guard compressionMode != .noCompression else {
                    // Compression disabled — the file already on disk is untouched and still valid.
                    DispatchQueue.main.async { completion(isUsableFile(at: fileUrl) ? (fileUrl, false) : nil) }
                    return
                }

                // Use caller-supplied EXIF if available to avoid a redundant file open
                let originalMetadata = existingMetadata ?? EXIFMetadataHelper.extractEXIF(from: fileUrl)
                let shouldCompress = isToCompressFile(fromPath: fileUrl.path, compressionMode: compressionMode)

                // Inner pool scopes the original full-res UIImage (~47 MB).
                // When shouldCompress is true, imageToSave is a new smaller UIImage and the
                // original is eligible for release when this pool drains — before saveImageWithEXIF.
                // When shouldCompress is false, imageToSave == original (same reference), so the
                // pool provides no early-release benefit, but autoreleased objects are still bounded.
                var imageToSave: UIImage?
                autoreleasepool {
                    guard let original = load(fileURL: fileUrl) else { return }
                    imageToSave = (shouldCompress ? original.resizedForCompression(to: compressionMode) : nil) ?? original
                }

                guard let imageToSave else {
                    // Source file couldn't be loaded — whatever is at fileUrl is not usable.
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                let outputURL = stagingURL(for: fileUrl, extension: "jpg")
                defer { try? FileManager.default.removeItem(at: outputURL) }

                var encoded = false
                do {
                    try EXIFMetadataHelper.saveImageWithEXIF(image: imageToSave, to: outputURL, metadata: originalMetadata)
                    encoded = true
                } catch {
                    // Bake orientation into the pixels when JPEG encoding strips EXIF.
                    if let data = imageToSave.fixedOrientation().jpegData(compressionQuality: 1.0) {
                        do {
                            try data.write(to: outputURL, options: .atomic)
                            encoded = true
                        } catch {
                            encoded = false
                        }
                    }
                }

                let wroteJPEG = encoded && replaceOriginal(at: fileUrl, with: outputURL)
                let result: (URL, Bool)? = wroteJPEG || isUsableFile(at: fileUrl) ? (fileUrl, wroteJPEG) : nil
                DispatchQueue.main.async { completion(result) }
            }
            // Intentionally no completion() call here — `return` inside autoreleasepool only
            // exits that closure, so any call placed here would fire on every early-return path
            // causing a double invocation.
        }
    }
    
    // MARK: - Get file size from file manager
    private class func isToCompressFile(fromPath path: String, compressionMode: CompressionMode = .noCompression) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? UInt64,
              fileSize >= 1024 else {
            return false
        }

        // Float conversion before division to avoid integer truncation
        let sizeInMB = Float(fileSize) / (1024 * 1024)

        guard sizeInMB >= 1.0 else { return false }

        switch compressionMode {
        case .high:   return sizeInMB > 1
        case .medium: return sizeInMB > 3
        case .low:    return sizeInMB > 5
        default:      return false
        }
    }
    
    class func load(fileURL: URL) -> UIImage? {
        // CGImageSource avoids allocating a Data buffer for the raw JPEG bytes before decoding
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        // Preserve EXIF orientation so fixedOrientation() inside saveImageWithEXIF can normalize it.
        // UIImage(cgImage:) always defaults to .up, losing the rotation metadata.
        var uiOrientation = UIImage.Orientation.up
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let raw = props[kCGImagePropertyOrientation as String] as? UInt32,
           let cgOrientation = CGImagePropertyOrientation(rawValue: raw) {
            uiOrientation = UIImage.Orientation(cgOrientation)
        }

        return UIImage(cgImage: cgImage, scale: 1.0, orientation: uiOrientation)
    }
}


// MARK: - Compress UIImage
extension UIImage {
    
    private func jpeg(_ jpegQuality: CompressionMode) -> Data? {
        return jpegData(compressionQuality: jpegQuality.rawValue)
    }
    
    private func resized(to compressionMode: CompressionMode) -> UIImage? {
        if compressionMode == .noCompression{
            return self
        }
        let newTargetSize = compressionMode.imageResolution
        let widthRatio = newTargetSize.width / size.width
        let heightRatio = newTargetSize.height / size.height
        let scaleFactor = min(widthRatio, heightRatio)
        
        let newSize = CGSize(width: size.width * scaleFactor, height: size.height * scaleFactor)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        
        let resizedImage = renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
        
        return resizedImage
    }
    
    private func compressed(quality: CGFloat) -> Data? {
        return self.jpegData(compressionQuality: quality)
    }
    
    private func convertDataToImage(imageData: Data?) -> UIImage? {
        guard let imageData, let image = UIImage(data: imageData) else { return nil }
        return image
    }
    
    func compressImage(compressionMode:CompressionMode, initialQuality: CGFloat = 0.9, decrement: CGFloat = 0.1) -> Data? {
        guard let resizedImage = self.resized(to: compressionMode) else { return nil }
        var targetSizeInMB: Double = 2
        
        var quality = initialQuality
        var imageData = resizedImage.jpeg(compressionMode)
        if let sizeInMB = imageData?.getSizeInMB(){
            targetSizeInMB = sizeInMB * compressionMode.rawValue
        }
        
        while let data = imageData, Double(data.count) / (1024 * 1024) > targetSizeInMB, quality > decrement {
            quality -= decrement
            imageData = resizedImage.jpegData(compressionQuality: quality)
        }
        return imageData
    }
    
    func resizedForCompression(to compressionMode: CompressionMode) -> UIImage? {
        return self.resized(to: compressionMode)
    }
    
}

extension Data {
    func getSizeInMB() -> Double {
        return Double(count) / (1024.0 * 1024.0)
    }
}

extension MediaCompressor {
    static func localize(_ key: String) -> String {
        let lang = UserDefaults.standard.value(forKey: "selected-language") as? String ?? "en"
        guard let path = Bundle.main.path(forResource: lang, ofType: "lproj") else {
            return NSLocalizedString(key, comment: "")
        }
        guard let bundle = Bundle(path: path) else {
            return NSLocalizedString(key, comment: "")
        }
        return NSLocalizedString(key, bundle: bundle, comment: "")
    }
}
