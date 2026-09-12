import Combine
import Foundation

/// Which page a control panel surface shows. The popover and the separate
/// window keep their own instance, so opening settings from the status item
/// menu does not move the page under a window the user left on the meters.
final class ControlPanelPresentation: ObservableObject {
    @Published var showsSettings: Bool

    init(showsSettings: Bool = false) {
        self.showsSettings = showsSettings
    }
}
