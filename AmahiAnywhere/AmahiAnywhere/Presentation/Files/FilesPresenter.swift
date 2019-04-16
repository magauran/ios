//
//  FilesPresenter.swift
//  AmahiAnywhere
//
//  Created by Chirag Maheshwari on 08/03/18.
//  Copyright © 2018 Amahi. All rights reserved.
//

import Foundation
import Lightbox
import CoreData
import AVFoundation

internal protocol FilesView : BaseView {
    func initFiles(_ files: [ServerFile])
    
    func updateFiles(_ files: [ServerFile])
    
    func updateRefreshing(isRefreshing: Bool)
    
    func present(_ controller: UIViewController)
    
    func playMedia(at url: URL)
    
    func playAudio(_ items: [AVPlayerItem], startIndex: Int, currentIndex: Int,_ URLs: [URL])
    
    func webViewOpenContent(at url: URL, mimeType: MimeType)
    
    func shareFile(at url: URL, from sender : UIView?)
    
    func updateDownloadProgress(for row: Int, downloadJustStarted: Bool, progress: Float)
    
    func dismissProgressIndicator(at url: URL, completion: @escaping () -> Void)
}

internal class FilesPresenter: BasePresenter {
    
    weak private var view: FilesView?
    private var offlineFiles : [String: OfflineFile]?
    
    var fetchedResultsController : NSFetchedResultsController<NSFetchRequestResult>? {
        didSet {
            executeSearch()
        }
    }
    
    init(_ view: FilesView) {
        self.view = view
    }
    
    func detachView() {
        self.view = nil
    }
    
    func getFiles(_ share: ServerShare, directory: ServerFile? = nil) {
        
        self.view?.updateRefreshing(isRefreshing: true)
        
        ServerApi.shared!.getFiles(share: share, directory: directory) { (serverFilesResponse) in
            
            self.view?.updateRefreshing(isRefreshing: false)
            
            guard let serverFiles = serverFilesResponse else {
                self.view?.showError(message: StringLiterals.genericNetworkError)
                return
            }
            
            self.view?.initFiles(serverFiles)
            self.view?.updateFiles(serverFiles.sorted(by: ServerFile.lastModifiedSorter))
        }
    }
    
    func filterFiles(_ searchText: String, files: [ServerFile], sortOrder: FileSort) {
        if searchText.count > 0 {
            let filteredFiles = files.filter { file in
                return file.name!.localizedCaseInsensitiveContains(searchText)
            }
            self.reorderFiles(files: filteredFiles, sortOrder: sortOrder)
        } else {
            self.reorderFiles(files: files, sortOrder: sortOrder)
        }
    }
    
    func reorderFiles(files: [ServerFile], sortOrder: FileSort) {
        let sortedFiles = files.sorted(by: getSorter(sortOrder))
        self.view?.updateFiles(sortedFiles)
    }
    
    private func getSorter(_ sortOrder: FileSort) -> ((ServerFile, ServerFile) -> Bool) {
        switch sortOrder {
        case .modifiedTime:
            return ServerFile.lastModifiedSorter
        case .name:
            return ServerFile.nameSorter
        }
    }
    
    func handleFileOpening(fileIndex: Int, files: [ServerFile], from sender : UIView?) {
        let file = files[fileIndex]

        let type = file.mimeType
        AmahiLogger.log(": Matched type is (type), FILE MIMETYPE \(file.mime_type ?? "")")

        switch type {
            
        case .image:
            // prepare ImageViewer
            let controller = LightboxController(images: prepareImageArray(files), startIndex: fileIndex)
            controller.dynamicBackground = true
            self.view?.present(controller)
            
        case .video, .flac:
            // TODO: open VideoPlayer and play the file
            
            guard let url = ServerApi.shared!.getFileUri(file) else {
                AmahiLogger.log("Invalid file URL, file cannot be opened")
                return
            }
            self.view?.playMedia(at: url)
            
        case .audio:
            let audioURLs = prepareAudioItems(files)
            var arrangedURLs = [URL]()
            
            for (index, url) in audioURLs.enumerated() {
                arrangedURLs.insert(url, at: arrangedURLs.endIndex)
            }
            
            var playerItems = [AVPlayerItem]()
            
            arrangedURLs.forEach({playerItems.append(AVPlayerItem(url: $0))})
            
            self.view?.playAudio(playerItems, startIndex: 0, currentIndex: fileIndex, arrangedURLs)
            break
            
        case .code, .presentation, .sharedFile, .document, .spreadsheet:
            func handleFileOpening(with fileURL: URL) {
                weak var weakSelf = self
                if type == .sharedFile {
                    weakSelf?.view?.shareFile(at: fileURL, from: sender)
                } else {
                    weakSelf?.view?.webViewOpenContent(at: fileURL, mimeType: type)
                }
            }

            if FileManager.default.fileExistsInCache(file) {
                let fileURL = FileManager.default.localPathInCache(for: file)
                handleFileOpening(with: fileURL)
            } else {
                downloadFile(at: fileIndex, file, mimeType: type, from: sender) { fileURL in
                    handleFileOpening(with: fileURL)
                }
            }

        default:
            // TODO: show list of apps that can open the file
            return
        }
    }
    
    func shareFile(_ file: ServerFile, fileIndex: Int, from sender: UIView?) {
        if FileManager.default.fileExistsInCache(file) {
            let path = FileManager.default.localPathInCache(for: file)
            self.view?.shareFile(at: path, from: sender)
        } else {
            downloadFile(at: fileIndex, file, mimeType: file.mimeType, from: sender) { [weak self] filePath in
                self?.view?.shareFile(at: filePath, from: sender)
            }
        }
    }
    
    public func makeFileAvailableOffline(_ serverFile: ServerFile) {
        
        let delegate = UIApplication.shared.delegate as! AppDelegate
        let stack = delegate.stack
        
        var path = serverFile.getPath().replacingOccurrences(of: "/", with: "-")
        if path.first == "-" {
            path.removeFirst()
        }
        
        guard let url = ServerApi.shared!.getFileUri(serverFile) else {
            AmahiLogger.log("Invalid file URL, file cannot be downloaded")
            return
        }
        
        let offlineFile = OfflineFile(name: serverFile.getNameOnly(),
                                      mime: serverFile.mime_type!,
                                      size: serverFile.size!,
                                      mtime: serverFile.mtime!,
                                      fileUri: url.absoluteString,
                                      localPath: path,
                                      progress: 1,
                                      state: OfflineFileState.downloading,
                                      context: stack.context)
        try? stack.saveContext()
        
        DownloadService.shared.startDownload(offlineFile)
        loadOfflineFiles()
    }
    
    private func downloadFile(at fileIndex: Int ,
                              _ serverFile: ServerFile,
                              mimeType: MimeType,
                              from sender : UIView?,
                              completion: @escaping (_ filePath: URL) -> Void) {
        
        self.view?.updateDownloadProgress(for: fileIndex, downloadJustStarted: true, progress: 0.0)
        
        // cleanup temp files in background
        DispatchQueue.global(qos: .background).async {
            FileManager.default.cleanUpFiles(in: FileManager.default.temporaryDirectory,
                                             folderName: "cache")
        }
        
        Network.shared.downloadFileToStorage(file: serverFile, progressCompletion: { progress in
            self.view?.updateDownloadProgress(for: fileIndex, downloadJustStarted: false, progress: progress)
        }, completion: { (wasSuccessful) in
            
            if !wasSuccessful  {
                self.view?.showError(message: StringLiterals.errorDownloadingFileMessage)
                return
            }
            
            let filePath = FileManager.default.localPathInCache(for: serverFile)
            
            self.view?.dismissProgressIndicator(at: filePath, completion: {
                completion(filePath)
            })
        })
    }
    
    private func prepareImageArray(_ files: [ServerFile]) -> [LightboxImage] {
        var images: [LightboxImage] = [LightboxImage] ()
        for file in files where file.mimeType == .image {
            guard let url = ServerApi.shared!.getFileUri(file) else {
                AmahiLogger.log("Invalid file URL, file cannot be opened")
                continue
            }
            images.append(LightboxImage(imageURL: url, text: file.name!))
        }
        return images
    }
    
    private func prepareAudioItems(_ files: [ServerFile]) -> [URL] {
        var audioURLs = [URL]()
        
        for file in files where file.mimeType == .audio {
            guard let url = ServerApi.shared!.getFileUri(file) else {
                AmahiLogger.log("Invalid file URL, file cannot be opened")
                continue
            }
            audioURLs.append(url)
        }
        return audioURLs
    }
    
    func loadOfflineFiles() {
        
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "OfflineFile")
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "downloadDate", ascending: false)]
        
        let delegate = UIApplication.shared.delegate as! AppDelegate
        let stack = delegate.stack
        
        fetchedResultsController = NSFetchedResultsController(fetchRequest: fetchRequest,
                                                              managedObjectContext: stack.context,
                                                              sectionNameKeyPath: nil, cacheName: nil)
        if let files = fetchedResultsController?.fetchedObjects as! [OfflineFile]? {
            
            var dictionary = [String : OfflineFile]()
            
            for file in files {
                dictionary[file.name!] = file
            }
            AmahiLogger.log("Offline Files \(dictionary)")
            
            self.offlineFiles = dictionary
        } else {
            AmahiLogger.log("Detched Objects returned was nil")
            self.offlineFiles = [:]
        }
    }
    
    func checkFileOfflineState(_ file: ServerFile) -> OfflineFileState {
        
        if let offlineFile = offlineFiles![file.name!] {
            
            if file.mtime! != offlineFile.mtime! || file.size! != offlineFile.size {
                return .outdated
            }
            
            return offlineFile.stateEnum
        } else {
            return .none
        }
    }
    
    private func executeSearch() {
        if let fc = fetchedResultsController {
            do {
                try fc.performFetch()
            } catch let e as NSError {
                AmahiLogger.log("Error while trying to perform a search: \n\(e)\n\(String(describing: fetchedResultsController))")
            }
        }
    }
}
