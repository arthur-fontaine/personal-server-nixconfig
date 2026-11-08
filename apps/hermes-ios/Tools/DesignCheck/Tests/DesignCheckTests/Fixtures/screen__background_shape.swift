// expect: styling-in-screen shape-in-screen layout-literal
struct A: View { var body: some View { Text("x").background(.fill, in: RoundedRectangle(cornerRadius: 24)) } }
