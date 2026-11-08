// expect: styling-in-screen layout-literal
struct A: View { var body: some View { Text("x").tint(.red).clipShape(.capsule).cornerRadius(8) } }
