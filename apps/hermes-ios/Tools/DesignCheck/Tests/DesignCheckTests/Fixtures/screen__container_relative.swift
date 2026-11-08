// expect: layout-literal
struct A: View { var body: some View { Text("x").containerRelativeFrame(.horizontal) { w, _ in w * 0.5 } } }
