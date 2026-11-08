// expect: untyped-public-api
public struct Swatch<S: ShapeStyle>: View { let fill: S ; public init(fill: S) { self.fill = fill } ; public var body: some View { EmptyView() } }
