//
//  Extensions.swift
//  SSMediaManager
//
//  Created by Apple on 12/06/22.
//

import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import AVFoundation

public enum CompressionMode: CGFloat {
    case low     = 0.75
    case medium  = 0.5
    case high    = 0.25
    case noCompression = 1.0
    
    var imageResolution: CGSize {
        switch self {
        case .low:
            return CGSize(width: 1920, height: 1080)
        case .medium:
            return CGSize(width: 1280, height: 720)
        case .high:
            return CGSize(width: 640, height: 480)
        case .noCompression:
            return CGSize(width: 1920, height: 1080)
        }
    }
}

extension TimeZone {
    func timeZoneOffsetInMinutes() -> Int {
        let seconds = secondsFromGMT()
        let minutes = seconds / 60
        return -(minutes)
    }
    func offsetFromGMT() -> String
    {
        let localTimeZoneFormatter = DateFormatter()
        localTimeZoneFormatter.timeZone = self
        localTimeZoneFormatter.dateFormat = "Z"
        return localTimeZoneFormatter.string(from: Date())
    }
}
// MARK: - EXIF Metadata Utilities
public class EXIFMetadataHelper {

    // Shared CIContext — creating one per saveImageWithEXIF call allocates Metal/GPU resources each time
    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Sanitize string values for S3 metadata headers (US-ASCII only, no control characters)
    private static func sanitizeHeaderValue(_ value: String) -> String? {
        // Remove non-ASCII characters and control characters
        let sanitized = value
            .components(separatedBy: .controlCharacters).joined()
            .components(separatedBy: .newlines).joined()
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Only allow printable ASCII characters (32-126)
        let asciiSanitized = sanitized.unicodeScalars
            .filter { $0.value >= 32 && $0.value <= 126 }
            .map { Character($0) }
        
        let result = String(asciiSanitized)
        return result.isEmpty ? nil : result
    }
    
    /// Extract EXIF metadata from image file URL
    public static func extractEXIF(from fileURL: URL) -> [String: Any]? {
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            return nil
        }
        return metadata
    }
    
    /// Extract EXIF metadata from image data
    public static func extractEXIF(from imageData: Data) -> [String: Any]? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            return nil
        }
        return metadata
    }
    
    /// Extract metadata from video file URL
    static func extractVideoMetadata(from fileURL: URL) -> [String: Any]? {
        let asset = AVAsset(url: fileURL)
        var metadata: [String: Any] = [:]
        
        // Extract common metadata
        let commonMetadata = asset.commonMetadata
        for item in commonMetadata {
            if let key = item.commonKey?.rawValue,
               let value = item.value {
                metadata[key] = value
            }
        }
        
        // Extract metadata by format (QuickTime, ID3, etc.)
        for format in asset.availableMetadataFormats {
            let formatMetadata = asset.metadata(forFormat: format)
            for item in formatMetadata {
                if let key = item.key as? String,
                   let value = item.value {
                    metadata[key] = value
                }
            }
        }
        
        // Extract creation date
        if let creationDate = asset.creationDate {
            if let dateValue = creationDate.value as? Date {
                metadata["creationDate"] = dateValue
            } else if let dateString = creationDate.stringValue {
                metadata["creationDate"] = dateString
            }
        }
        
        // Extract location - try multiple methods
        // Method 1: QuickTime metadata (ISO 6709 format)
        let locationMetadata = asset.metadata(forFormat: .quickTimeMetadata).filter {
            $0.identifier == .quickTimeMetadataLocationISO6709
        }
        if let locationItem = locationMetadata.first,
           let locationString = locationItem.stringValue {
            metadata["location"] = locationString
        }
        
        // Method 2: Try common location key
        if metadata["location"] == nil {
            for item in asset.commonMetadata {
                if item.commonKey == .commonKeyLocation,
                   let locationString = item.stringValue {
                    metadata["location"] = locationString
                    break
                }
            }
        }
        
        // Extract video track properties
        if let videoTrack = asset.tracks(withMediaType: .video).first {
            metadata["videoWidth"] = Int(videoTrack.naturalSize.width)
            metadata["videoHeight"] = Int(videoTrack.naturalSize.height)
            metadata["videoFrameRate"] = videoTrack.nominalFrameRate
            metadata["videoDuration"] = asset.duration.seconds
        }
        
        return metadata.isEmpty ? nil : metadata
    }
    
    /// Convert EXIF metadata to S3 metadata headers format
    static func convertToS3Headers(exifMetadata: [String: Any]?, fileURL: URL? = nil) -> [String: String] {
        guard let metadata = exifMetadata else { return [:] }
        
        var headers: [String: String] = [:]
        
        // EXIF dictionary
        if let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let dateTime = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
               let sanitized = sanitizeHeaderValue(dateTime) {
                headers["x-amz-meta-exif-datetime-original"] = sanitized
            }
        }
        
        // TIFF dictionary
        if let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            if let make = tiff[kCGImagePropertyTIFFMake as String] as? String,
               let sanitized = sanitizeHeaderValue(make) {
                headers["x-amz-meta-exif-make"] = sanitized
            }
            if let model = tiff[kCGImagePropertyTIFFModel as String] as? String,
               let sanitized = sanitizeHeaderValue(model) {
                headers["x-amz-meta-exif-model"] = sanitized
            }
            if let software = tiff[kCGImagePropertyTIFFSoftware as String] as? String,
               let sanitized = sanitizeHeaderValue(software) {
                headers["x-amz-meta-exif-software"] = sanitized
            }
        }
        
        // GPS dictionary — capped to 6 decimal places
        if let gps = metadata[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            if let latitude = gps[kCGImagePropertyGPSLatitude as String] as? Double,
               let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String {
                headers["x-amz-meta-exif-gps-latitude"] = String(format: "%.6f%@", latitude, latitudeRef)
            }
            if let longitude = gps[kCGImagePropertyGPSLongitude as String] as? Double,
               let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String {
                headers["x-amz-meta-exif-gps-longitude"] = String(format: "%.6f%@", longitude, longitudeRef)
            }
        }
        
        // Width/Height — read from saved file on disk (reflects actual compressed dimensions)
        if let url = fileURL,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            if let width = props[kCGImagePropertyPixelWidth as String] as? Int {
                headers["x-amz-meta-image-width"] = "\(width)"
            }
            if let height = props[kCGImagePropertyPixelHeight as String] as? Int {
                headers["x-amz-meta-image-height"] = "\(height)"
            }
        } else {
            // Fallback to original EXIF if file not available
            if let width = metadata[kCGImagePropertyPixelWidth as String] as? Int {
                headers["x-amz-meta-image-width"] = "\(width)"
            }
            if let height = metadata[kCGImagePropertyPixelHeight as String] as? Int {
                headers["x-amz-meta-image-height"] = "\(height)"
            }
        }
        
        // Always upright — pixels are physically rotated before save
        headers["x-amz-meta-image-orientation"] = "1"
        
        return headers
    }
    
    /// Convert video metadata to S3 metadata headers format
    static func convertVideoMetadataToS3Headers(videoMetadata: [String: Any]?) -> [String: String] {
        guard let metadata = videoMetadata else { return [:] }
        
        var headers: [String: String] = [:]
        
        // Creation date
        if let creationDate = metadata["creationDate"] {
            if let date = creationDate as? Date {
                let formatter = ISO8601DateFormatter()
                headers["x-amz-meta-video-creation-date"] = formatter.string(from: date)
            } else if let dateString = creationDate as? String,
                      let sanitized = sanitizeHeaderValue(dateString) {
                headers["x-amz-meta-video-creation-date"] = sanitized
            }
        }
        
        // Location (ISO 6709 format) - usually safe but sanitize anyway
        if let location = metadata["location"] as? String,
           let sanitized = sanitizeHeaderValue(location) {
            headers["x-amz-meta-video-location"] = sanitized
        }
        
        // Video dimensions (numbers are always safe)
        if let width = metadata["videoWidth"] as? Int {
            headers["x-amz-meta-video-width"] = "\(width)"
        }
        if let height = metadata["videoHeight"] as? Int {
            headers["x-amz-meta-video-height"] = "\(height)"
        }
        
        // Frame rate - format to 2 decimal places
        if let frameRate = metadata["videoFrameRate"] as? Float {
            headers["x-amz-meta-video-framerate"] = String(format: "%.2f", frameRate)
        }
        
        // Duration - format to 2 decimal places
        if let duration = metadata["videoDuration"] as? Double {
            headers["x-amz-meta-video-duration"] = String(format: "%.2f", duration)
        }
        
        // Common metadata keys - sanitize all string values
        if let title = metadata[AVMetadataKey.commonKeyTitle.rawValue] as? String,
           let sanitized = sanitizeHeaderValue(title) {
            headers["x-amz-meta-video-title"] = sanitized
        }
        if let artist = metadata[AVMetadataKey.commonKeyArtist.rawValue] as? String,
           let sanitized = sanitizeHeaderValue(artist) {
            headers["x-amz-meta-video-artist"] = sanitized
        }
        if let software = metadata[AVMetadataKey.commonKeySoftware.rawValue] as? String,
           let sanitized = sanitizeHeaderValue(software) {
            headers["x-amz-meta-video-software"] = sanitized
        }
        if let make = metadata[AVMetadataKey.commonKeyMake.rawValue] as? String,
           let sanitized = sanitizeHeaderValue(make) {
            headers["x-amz-meta-video-make"] = sanitized
        }
        if let model = metadata[AVMetadataKey.commonKeyModel.rawValue] as? String,
           let sanitized = sanitizeHeaderValue(model) {
            headers["x-amz-meta-video-model"] = sanitized
        }
        
        return headers
    }
    
    /// Save image with EXIF metadata preserved
    public static func saveImageWithEXIF(image: UIImage, to fileURL: URL, metadata: [String: Any]?) throws {
        let uprightImage = image.fixedOrientation()

        guard let cgImage = uprightImage.cgImage ?? uprightImage.ciImage.flatMap({ ciImage in
            sharedCIContext.createCGImage(ciImage, from: ciImage.extent)
        }) else {
            throw NSError(domain: "EXIFMetadataHelper", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to get CGImage from UIImage"])
        }
        
        guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "EXIFMetadataHelper", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination"])
        }
        
        // Create a normalized metadata dictionary
        var finalMetadata = metadata ?? [:]

        // Force orientation to upright in all metadata locations
        finalMetadata[kCGImagePropertyOrientation as String] = 1

        if var tiff = finalMetadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            finalMetadata[kCGImagePropertyTIFFDictionary as String] = tiff
        }

        if var exif = finalMetadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifSubjectArea as String)
            finalMetadata[kCGImagePropertyExifDictionary as String] = exif
        }

        CGImageDestinationAddImage(destination, cgImage, finalMetadata as CFDictionary)
        
        if !CGImageDestinationFinalize(destination) {
            throw NSError(domain: "EXIFMetadataHelper", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize image destination"])
        }
    }
}

extension UIImage.Orientation {
    // UIKit uses the same left/right naming as CGImagePropertyOrientation.
    // UIImage(contentsOfFile:) on an EXIF-6 (CG .right) portrait JPEG sets imageOrientation = .right.
    init(_ cg: CGImagePropertyOrientation) {
        switch cg {
        case .up:            self = .up
        case .upMirrored:    self = .upMirrored
        case .down:          self = .down
        case .downMirrored:  self = .downMirrored
        case .left:          self = .left
        case .leftMirrored:  self = .leftMirrored
        case .right:         self = .right
        case .rightMirrored: self = .rightMirrored
        }
    }
}

extension UIImage {
    /// Returns a new image with orientation baked into the pixel buffer (.up) by redrawing it.
    /// UIImage.size already reports display dimensions, so we use it directly as the canvas.
    /// UIKit's draw(in:) applies the orientation transform, producing correctly-oriented pixels.
    func fixedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format)
            .image { _ in self.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

