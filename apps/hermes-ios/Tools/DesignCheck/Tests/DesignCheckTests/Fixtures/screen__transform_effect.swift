// expect: layout-literal
struct A: View { var body: some View { Text("x").transformEffect(.init(scaleX: 1.1, y: 1)) } }
