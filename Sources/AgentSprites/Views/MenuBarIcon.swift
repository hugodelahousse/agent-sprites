import AppKit

/// Loads the slime-based menu bar icon from bundled resources.
/// The icon is a template image so it adapts to light/dark mode automatically.
enum MenuBarIcon {
    static func makeImage() -> NSImage {
        guard let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "AgentSprites")!
        }

        if let url2x = Bundle.module.url(forResource: "MenuBarIcon@2x", withExtension: "png"),
           let image2x = NSImage(contentsOf: url2x) {
            let combined = NSImage(size: NSSize(width: 18, height: 18))
            for rep in image.representations {
                combined.addRepresentation(rep)
            }
            for rep in image2x.representations {
                rep.size = NSSize(width: 18, height: 18)
                combined.addRepresentation(rep)
            }
            combined.isTemplate = true
            return combined
        }

        image.isTemplate = true
        return image
    }
}
