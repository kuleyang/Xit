import Foundation

extension XTRepository
{
  func createTag(name: String,
                 targetSHA: String,
                 message: String?) throws
  {
    try performWriting {
      guard let targetCommit = try gtRepo.lookUpObject(bySHA: targetSHA,
                                                       objectType: .commit)
                                   as? GTCommit
      else { return }
      let signature = gtRepo.userSignatureForNow()
      
      try gtRepo.createTagNamed(name, target: targetCommit, tagger: signature,
                                message: message ?? "")
    }
  }
  
  func createLightweightTag(name: String, targetSHA: String) throws
  {
    try performWriting {
      guard let targetCommit = try gtRepo.lookUpObject(bySHA: targetSHA,
                                                       objectType: .commit)
                                   as? GTCommit
      else { return }
      
      try gtRepo.createLightweightTagNamed(name, target: targetCommit)
    }
  }
  
  func deleteTag(name: String) throws
  {
    try performWriting {
      let result = git_tag_delete(gtRepo.git_repository(), name)
      
      guard result == 0
      else {
        throw NSError.git_error(for: result)
      }
    }
  }
  
  func push(remote: String) throws
  {
    _ = try executeGit(args: ["push", "--all", remote], writes: true)
  }
  
  func checkout(branch: String) throws
  {
    try performWriting {
      // invalidate ref caches
      
      let branchRef = GTBranch.localNamePrefix().appending(pathComponent: branch)
      let ref = try gtRepo.lookUpReference(withName: branchRef)
      let options = GTCheckoutOptions(strategy: [.safe])
      
      try gtRepo.checkoutReference(ref, options: options)
    }
  }
  
  func checkout(sha: String) throws
  {
    guard let commit = try gtRepo.lookUpObject(bySHA: sha) as? GTCommit
    else { throw Error.unexpected }
    let options = GTCheckoutOptions(strategy: [.safe])
    
    try gtRepo.checkoutCommit(commit, options: options)
  }
  
  func stagePatch(_ patch: String) throws
  {
    _ = try executeGit(args: ["apply", "--cached"], stdIn: patch, writes: true)
  }
  
  func unstagePatch(_ patch: String) throws
  {
    _ = try executeGit(args: ["apply", "--cached", "--reverse"],
                       stdIn: patch,
                       writes: true)
  }
  
  func discardPatch(_ patch: String) throws
  {
    _ = try executeGit(args: ["apply", "--reverse"],
                       stdIn: patch,
                       writes: true)
  }
  
  func unstageAllFiles() throws
  {
    let headRef = try gtRepo.headReference()
    let index = try gtRepo.index()
    guard let headCommit = headRef.resolvedTarget as? GTCommit,
          let headTree = headCommit.tree
    else { throw Error.unexpected }
    
    try index.addContents(of: headTree)
    try index.write()
  }
  
  func renameRemote(old: String, new: String) throws
  {
    _ = try executeGit(args: ["remote", "rename", old, new], writes: true)
  }
}

extension XTRepository: Stashing
{
  // TODO: Don't require the message parameter
  public func stash(index: UInt, message: String?) -> Stash
  {
    return XTStash(repo: self, index: index, message: message)
  }
  
  @objc(saveStash:includeUntracked:error:)
  func saveStash(name: String?, includeUntracked: Bool) throws
  {
    var args = ["stash", "save"]
    
    if includeUntracked {
      args.append("--include-untracked")
    }
    if let name = name {
      args.append(name)
    }
    _ = try executeGit(args: args, stdIn: nil, writes: true)
  }
  
  func stashCheckoutOptions() -> GTCheckoutOptions
  {
    return GTCheckoutOptions(strategy: .safe)
  }
  
  public func popStash(index: UInt) throws
  {
    _ = try performWriting {
      try gtRepo.popStash(at: index, flags: [.reinstateIndex],
                          checkoutOptions: stashCheckoutOptions(),
                          progressBlock: nil)
    }
  }
  
  public func applyStash(index: UInt) throws
  {
    _ = try performWriting {
      try gtRepo.applyStash(at: index, flags: [.reinstateIndex],
                            checkoutOptions: stashCheckoutOptions(),
                            progressBlock: nil)
    }
  }
  
  public func dropStash(index: UInt) throws
  {
    _ = try performWriting {
      try gtRepo.dropStash(at: index)
    }
  }
  
  public func commitForStash(at index: UInt) -> Commit?
  {
    guard let stashRef = try? gtRepo.lookUpReference(withName: "refs/stash"),
          let stashLog = GTReflog(reference: stashRef),
          index < stashLog.entryCount,
          let entry = stashLog.entry(at: index),
          let oid = entry.updatedOID.map({ GitOID(oid: $0.git_oid().pointee) })
    else { return nil }
    
    return XTCommit(oid: oid, repository: gtRepo.git_repository())
  }
}

extension XTRepository: RemoteManagement
{
  public func remote(named name: String) -> Remote?
  {
    return XTRemote(name: name, repository: self)
  }
  
  public func addRemote(named name: String, url: URL) throws
  {
    _ = try executeGit(args: ["remote", "add", name, url.absoluteString],
                       writes: true)
  }
  
  public func deleteRemote(named name: String) throws
  {
    _ = try executeGit(args: ["remote", "rm", name],
                       writes: true)
  }
}

extension XTRepository: SubmoduleManagement
{
  public func addSubmodule(path: String, url: String) throws
  {
    _ = try executeGit(args: ["submodule", "add", "-f", url, path],
                       writes: true)
    /* still needs clone
    _ = try performWriting {
     git_submodule *gitSub = NULL;
     let result = git_submodule_add_setup(
        &gitSub, [gtRepo git_repository],
        [urlOrPath UTF8String], [path UTF8String], false);
     
     if ((result != 0) && (error != NULL)) {
      *error = [NSError git_errorFor:result];
      return NO;
     }
     // clone the sub-repo
     git_submodule_add_finalize(gitSub);
    }
    */
  }
  
  public func submodules() -> [XTSubmodule]
  {
    var submodules = [XTSubmodule]()
    
    gtRepo.enumerateSubmodulesRecursively(false) {
      (submodule, _, _) in
      if let submodule = submodule {
        submodules.append(XTSubmodule(repository: self, submodule: submodule))
      }
    }
    return submodules
  }
}
