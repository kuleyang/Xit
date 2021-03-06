import Cocoa

/// Provides access to repository config options. This class is an exception to
/// the rule that direct Objective Git usage should be avoided outside of
/// `XTRepository`.
class XTConfig: NSObject
{
  unowned let repository: XTRepository
  let config: GTConfiguration?
  var xitConfig: [String: String] = [:]
  
  var xitConfigURL: URL?
  {
    return repository.gitDirectoryURL.appendingPathComponent("xit-config.plist")
  }
  
  init(repository: XTRepository)
  {
    self.repository = repository
    self.config = try? repository.gtRepo.configuration()
    if config == nil {
      NSLog("Could not get config")
    }
    
    super.init()
    
    loadXitConfig()
  }
  
  final func urlString(forRemote remote: String) -> String?
  {
    return config?.string(forKey: remote)
  }
  
  final func loadXitConfig()
  {
    guard let xitConfigURL = xitConfigURL
    else {
      NSLog("Can't make Xit config URL")
      return
    }
    guard FileManager.default.fileExists(atPath: xitConfigURL.path)
    else { return }
    guard let configContents = NSMutableDictionary(contentsOf: xitConfigURL)
    else {
      NSLog("Can't read xit-config")
      return
    }
    guard let configCopy = configContents.mutableCopy() as? [String: String]
    else {
      NSLog("Can't copy config contents")
      return
    }
    
    xitConfig = configCopy
  }
  
  final func saveXitConfig()
  {
    guard let xitConfigURL = xitConfigURL
    else {
      NSLog("Can't make Xit config URL")
      return
    }
    
    if !(xitConfig as NSDictionary).write(to: xitConfigURL, atomically: true) {
      NSLog("Save config failed")
    }
  }
  
  /// Returns the `user.name` setting.
  final func userName() -> String?
  {
    return config?.string(forKey: "user.name")
  }
  
  /// Returns the `user.email` setting.
  final func userEmail() -> String?
  {
    return config?.string(forKey: "user.email")
  }

  /// Returns the `fetch.prune` setting.
  final func fetchPrune() -> Bool
  {
    return config?.bool(forKey: "fetch.prune") ?? false
  }
  
  /// Returns the prune setting for `remote`, or falls back to the general
  /// `fetch.prune` setting.
  final func fetchPrune(_ remote: String) -> Bool
  {
    guard let config = config
    else { return false }
    
    if config.bool(forKey: "remote.\(remote).prune") {
      return true
    }
    return fetchPrune()
  }
  
  /// Returns true if `--no-tags` is set for `remote.<remote>.tagOpt`.
  final func fetchTags(_ remote: String) -> Bool
  {
    guard let config = config
    else { return true }
    
    if config.string(forKey: "remote.\(remote).tagOpt") == "--no-tags" {
      return false
    }
    return UserDefaults.standard.bool(
        forKey: XTGitPrefsController.PrefKey.fetchTags)
  }
  
  final func commitTemplate() -> String?
  {
    return config?.string(forKey: "commit.template")
  }
}
