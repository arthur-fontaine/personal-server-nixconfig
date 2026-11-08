// expect: recursive-tint
import SwiftUI

struct Bar: View {
    let full: Bool
    var body: some View {
        ProgressView(value: 0.5).tint(full ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
    }
}
