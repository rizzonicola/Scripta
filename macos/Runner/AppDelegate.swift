import Cocoa
import FlutterMacOS

/// Riceve gli URL aperti dal Finder ("Apri con Scripta") tramite il meccanismo
/// ufficiale dei lifecycle delegate di Flutter, invece di sovrascrivere
/// `application(_:open:)` (metodo implementato da FlutterAppDelegate ma non
/// dichiarato nell'header pubblico).
private final class ExternalOpenLifecycleDelegate: NSObject, FlutterAppLifecycleDelegate {
  private var channel: FlutterMethodChannel?
  private var pendingPaths: [String] = []
  private var dartIsReady = false

  func connect(channel: FlutterMethodChannel) {
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, call.method == "ready" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // Da questo momento il Dart ha registrato il suo handler: gli eventi
      // successivi possono essere consegnati subito. Quelli accumulati
      // durante il launch vengono restituiti come risposta a "ready".
      self.dartIsReady = true
      let paths = self.pendingPaths
      self.pendingPaths.removeAll()
      result(paths)
    }
  }

  // Xcode 26 importa il requisito Objective-C `handleOpenURLs:` con il nome
  // Swift `handleOpen(_:)`. Il selector esplicito mantiene il collegamento
  // con FlutterAppLifecycleDelegate anche sulle versioni precedenti di Xcode.
  @objc(handleOpenURLs:)
  func handleOpen(_ urls: [URL]) -> Bool {
    let paths = urls.filter { $0.isFileURL }.map { $0.path }
    guard !paths.isEmpty else { return false }

    if dartIsReady, let channel = channel {
      channel.invokeMethod("open", arguments: paths)
    } else {
      pendingPaths.append(contentsOf: paths)
    }
    return true
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  private let externalOpenDelegate = ExternalOpenLifecycleDelegate()

  override func applicationWillFinishLaunching(_ notification: Notification) {
    super.applicationWillFinishLaunching(notification)
    // Registrato prima di `applicationDidFinishLaunching`: il Finder può
    // consegnare un documento durante il launch, e in quel caso i percorsi
    // devono finire nella coda del delegate invece di andare persi. Il canale
    // Dart viene collegato appena la finestra Flutter esiste (sotto).
    addApplicationLifecycleDelegate(externalOpenDelegate)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      externalOpenDelegate.connect(
        channel: FlutterMethodChannel(
          name: "io.github.scripta/external_open",
          binaryMessenger: controller.engine.binaryMessenger
        )
      )
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
