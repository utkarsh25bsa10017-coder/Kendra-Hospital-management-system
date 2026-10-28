import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Open at a comfortable size, centred; never smaller than a small laptop window.
    self.setContentSize(NSSize(width: 1320, height: 840))
    self.contentMinSize = NSSize(width: 820, height: 560)
    self.title = "Kendra HMS"
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
