// expect:
public struct Card: View {
    let inset: Spacing
    var radius: CGFloat { inset.points }
    public init(inset: Spacing) { self.inset = inset }
    public var body: some View {
        Text("x").font(.headline).padding(inset.points).background(.fill, in: RoundedRectangle(cornerRadius: radius)).padding(.top, 0)
    }
}
public extension View { private func helper(_ x: CGFloat) -> some View { self } }
