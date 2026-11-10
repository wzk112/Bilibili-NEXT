import SwiftUI

enum MobileSurface {
  static let background = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.09, green: 0.095, blue: 0.105, alpha: 1)
        : UIColor.systemBackground
    })
  static let inset = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.12, green: 0.125, blue: 0.135, alpha: 1)
        : UIColor.secondarySystemBackground
    })
}

struct MobileComposerIcon: View {
  let name: String
  var body: some View {
    Image(systemName: name).font(.system(size: 20, weight: .regular))
      .frame(width: 44, height: 44)
      .appGlassEffect(.regular.interactive(), in: .circle)
  }
}
