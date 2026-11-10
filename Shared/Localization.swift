// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// #18 Localization. SwiftUI string literals (Text("…"), Button("…"), Label("…", …)) are looked up
// in the String Catalog automatically. Many menu rows, skin names, toasts and alerts reach the views
// as plain `String`s instead (PadRow titles, enum labels, toast text), which SwiftUI shows verbatim.
// `.loc` looks those up at the point where they are drawn, using the English text as the key;
// a string with no entry (a game title, a file name) comes back unchanged.
import Foundation

extension String {
    /// The current-language text for this English source string (unchanged when not in the catalog).
    var loc: String {
        guard !isEmpty else { return self }
        return Bundle.main.localizedString(forKey: self, value: self, table: nil)
    }
}

extension Optional where Wrapped == String {
    var loc: String? { map(\.loc) }
}
