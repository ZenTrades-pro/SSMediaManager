//
//  SSMediaManager.swift
//  SSMediaManager
//
//  Created by Apple on 21/06/22.
//

import Foundation

public class SSMediaManager{
    nonisolated(unsafe) public static let shared = SSMediaManager()
    
    private init(){
    }
    
    fileprivate func uploadFile(_ media: SSMedia, _ baseS3URL: String, _ indexPath: IndexPath?, _ index: Int?, _ completion: @escaping UploadCompletion) {
        APIManager.shared.getUploadUrl(media: media, baseS3URL: baseS3URL,indexPath: indexPath!, index: index!) { json, data, response, error, indexPath, index in
            var mediaWithS3 = media
            if let s3url = json?["s3URL"] as? String{
                mediaWithS3.serverUrl = s3url
            }
            if let uploadUrl = json?["uploadURL"] as? String{
                APIManager.shared.uploadMediaWith(uploadUrl: uploadUrl, media: mediaWithS3,indexPath: indexPath, index: index, json: json,completion: completion)
            }else{
                completion(nil, nil, nil, error,indexPath,index)
            }
        }
    }
    
    public func uploadFileWith(media:SSMedia, baseS3URL: String, indexPath: IndexPath?=nil, index: Int?=0, completion:@escaping UploadCompletion){
        if((media.mimeType ?? "").contains("video")){
            let inputUrl = URL(fileURLWithPath:media.filePath ?? "")
            
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
                if error == nil, url != nil{
                    try? FileManager.default.removeItem(at: inputUrl)
                    try? FileManager.default.moveItem(at: outputUrl, to: inputUrl)
                    var tempMedia = mediaWithMetadata
                    tempMedia.filePath = inputUrl.path
                    tempMedia.mimeType = "video/mp4"
                    self.uploadFile(tempMedia, baseS3URL, indexPath, index, completion)
                }else{
                    debugPrint("Error in compression>>\(error)")
                    self.uploadFile(mediaWithMetadata, baseS3URL, indexPath, index, completion)
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
                self.uploadFile(mediaWithEXIF, baseS3URL, indexPath, index, completion)
            }
            
        }else{
            self.uploadFile(media, baseS3URL, indexPath, index, completion)
        }
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

