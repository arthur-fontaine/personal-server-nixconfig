// expect: untyped-public-api
public struct Swatch<S: ShapeStyle>: View { let fill: S ; public init<T: ShapeStyle>(fill: T) where T == S { self.fill = fill } ; public var body: some View { EmptyView() } }
