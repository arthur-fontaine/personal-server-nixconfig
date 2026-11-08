// expect: shape-in-screen stroke-or-shadow layout-literal
struct A: View { var body: some View { Text("x").overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.tint, lineWidth: 1) } } }
