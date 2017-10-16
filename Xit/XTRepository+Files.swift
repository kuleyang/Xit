import Foundation

extension XTRepository: FileContents
{
  static let textNames = ["AUTHORS", "CONTRIBUTING", "COPYING", "LICENSE",
                          "Makefile", "README"]
  
  /// Returns true if the file seems to be text, based on its name.
  public func isTextFile(_ path: String, commit: String?) -> Bool
  {
    let name = (path as NSString).lastPathComponent
    guard !name.isEmpty
    else { return false }
    
    if XTRepository.textNames.contains(name) {
      return true
    }
    
    let ext = (name as NSString).pathExtension
    guard !ext.isEmpty
    else { return false }
    
    let unmanaged = UTTypeCreatePreferredIdentifierForTag(
          kUTTagClassFilenameExtension, ext as CFString, nil)
    let utType = unmanaged?.takeRetainedValue()
    
    return utType.map { UTTypeConformsTo($0, kUTTypeText) } ?? false
  }
  
  public func contentsOfFile(path: String, at commit: Commit) -> Data?
  {
    // TODO: make a Tree protocol to eliminate this cast
    guard let commit = commit as? XTCommit,
          let tree = commit.tree,
          let entry = tree.entry(path: path),
          let blob = entry.object as? Blob
    else { return nil }
    
    return blob.makeData()
  }
  
  public func contentsOfStagedFile(path: String) -> Data?
  {
    var result: Data?
    
    _ = try? stagedBlob(file: path)?.withData {
      (data) in
      result = (data as NSData).copy() as? Data
    }
    return result
  }
  
  public func stagedBlob(file: String) -> Blob?
  {
    guard let index = try? gtRepo.index(),
          (try? index.refresh()) != nil,
          let indexEntry = index.entry(withPath: file),
          let indexObject = try? GTObject(indexEntry: indexEntry)
    else { return nil }
    
    return indexObject as? GTBlob
  }
  
  public func fileBlob(ref: String, path: String) -> Blob?
  {
    guard let headTree = XTCommit(ref: ref, repository: self)?.tree,
          let headEntry = headTree.entry(path: path),
          let headObject = headEntry.object
    else { return nil }
    
    return headObject as? Blob
  }
  
  /// Returns a file URL for a given relative path.
  public func fileURL(_ file: String) -> URL
  {
    return repoURL.appendingPathComponent(file)
  }
}

extension XTRepository: FileDiffing
{
  /// Returns a diff maker for a file at the specified commit, compared to the
  /// parent commit.
  public func diffMaker(forFile file: String,
                        commitOID: OID,
                        parentOID: OID?) -> XTDiffMaker.DiffResult?
  {
    guard let toCommit = commit(forOID: commitOID as! GitOID) as? XTCommit
    else { return nil }
    
    guard isTextFile(file, commit: commitOID.sha)
    else { return .binary }
    
    var fromSource = XTDiffMaker.SourceType.data(Data())
    var toSource = XTDiffMaker.SourceType.data(Data())
    
    if let toTree = toCommit.tree,
       let toEntry = toTree.entry(path: file),
       let toBlob = toEntry.object as? GitBlob {
      toSource = .blob(toBlob)
    }
    
    if let parentOID = parentOID,
       let parentCommit = (commit(forOID: parentOID as! GitOID) as? XTCommit),
       let fromTree = parentCommit.tree,
       let fromEntry = fromTree.entry(path: file),
       let fromBlob = fromEntry.object as? GitBlob {
      fromSource = .blob(fromBlob)
    }
    
    return .diff(XTDiffMaker(from: fromSource, to: toSource, path: file))
  }
  
  // Returns a file diff for a given commit.
  public func diff(for path: String,
                   commitSHA sha: String,
                   parentOID: OID?) -> XTDiffDelta?
  {
    guard let diff = self.diff(forSHA: sha, parent: parentOID)
    else { return nil }
    
    return delta(from: diff, path: path)
  }
  
  /// Returns a diff maker for a file in the index, compared to the workspace
  /// file.
  public func stagedDiff(file: String) -> XTDiffMaker.DiffResult?
  {
    guard isTextFile(file, commit: XTStagingSHA)
    else { return .binary }
    
    guard let headRef = self.headRef
    else { return nil }
    let indexBlob = stagedBlob(file: file)
    let headBlob = fileBlob(ref: headRef, path: file)
    
    return .diff(XTDiffMaker(from: XTDiffMaker.SourceType(headBlob),
                             to: XTDiffMaker.SourceType(indexBlob),
                             path: file))
  }
  
  /// Returns a diff maker for a file in the workspace, compared to the index.
  public func unstagedDiff(file: String) -> XTDiffMaker.DiffResult?
  {
    guard isTextFile(file, commit: nil)
    else { return .binary }
    
    let url = self.repoURL.appendingPathComponent(file)
    let exists = FileManager.default.fileExists(atPath: url.path)
    
    do {
      let data = exists ? try Data(contentsOf: url) : Data()
      
      if let index = try? gtRepo.index(),
         let indexEntry = index.entry(withPath: file),
         let indexBlob = try? GTObject(indexEntry: indexEntry) as? GTBlob {
        return .diff(XTDiffMaker(from: XTDiffMaker.SourceType(indexBlob),
                                 to: .data(data), path: file))
      }
      else {
        return .diff(XTDiffMaker(from: .data(Data()),
                                 to: .data(data),
                                 path: file))
      }
    }
    catch {
      return nil
    }
  }
  
  public func blame(for path: String,
                    from startOID: OID?, to endOID: OID?) -> Blame?
  {
    return GitBlame(repository: self, path: path, from: startOID, to: endOID)
  }
  
  public func blame(for path: String,
                    data fromData: Data?, to endOID: OID?) -> Blame?
  {
    return GitBlame(repository: self, path: path,
                    data: fromData ?? Data(), to: endOID)
  }
}

extension XTRepository
{
  
  /// Returns the diff for the referenced commit, compared to its first parent
  /// or to a specific parent.
  func diff(forSHA sha: String, parent parentOID: OID?) -> GTDiff?
  {
    let parentSHA = parentOID?.sha ?? ""
    let key = sha.appending(parentSHA) as NSString
    
    if let diff = diffCache.object(forKey: key) {
      return diff
    }
    else {
      guard let commit = (try? gtRepo.lookUpObject(bySHA: sha)) as? GTCommit
      else { return nil }
      
      let parents = commit.parents
      let parent: GTCommit? = (parentSHA == "")
          ? parents.first
          : parents.first(where: { $0.sha == parentSHA })
      
      guard let diff = try? GTDiff(oldTree: parent?.tree,
                                   withNewTree: commit.tree,
                                   in: gtRepo, options: nil)
      else { return nil }
      
      diffCache.setObject(diff, forKey: key)
      return diff
    }
  }
  
  /// Applies the given patch hunk to the specified file in the index.
  /// - parameter path: Target file path
  /// - parameter hunk: Hunk to be applied
  /// - parameter stage: True if the change is being staged, falses if unstaged
  /// (the patch should be reversed)
  func patchIndexFile(path: String, hunk: DiffHunk, stage: Bool) throws
  {
    var encoding = String.Encoding.utf8
    let index = try gtRepo.index()
    
    if let entry = index.entry(withPath: path) {
      if (hunk.newStart == 1) || (hunk.oldStart == 1) {
        let status = try self.status(file: path)
        
        if stage {
          if status.0 == .deleted {
            try self.stage(file: path)
            return
          }
        }
        else {
          switch status.1 {
          case .added, .deleted:
            // If it's added/deleted in the index, and we're unstaging, then the
            // hunk must cover the whole file
            try unstage(file: path)
            return
          default:
            break
          }
        }
      }
      
      guard let blob = (try entry.gtObject()) as? GTBlob,
            let data = blob.data(),
            let text = String(data: data, usedEncoding: &encoding)
      else { throw Error.unexpected }
      
      guard let patchedText = hunk.applied(to: text, reversed: !stage)
      else { throw Error.patchMismatch }
      
      guard let patchedData = patchedText.data(using: encoding)
      else { throw Error.unexpected }
      
      try index.add(patchedData, withPath: path)
      try index.write()
      return
    }
    else {
      let status = try self.status(file: path)
      
      // Assuming the hunk covers the whole file
      if stage && status.0 == .untracked && hunk.newStart == 1 {
        try self.stage(file: path)
        return
      }
      else if !stage && (status.1 == .deleted) && (hunk.oldStart == 1) {
        try unstage(file: path)
        return
      }
    }
    throw Error.patchMismatch
  }
}
