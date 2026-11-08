// expect: styling-in-screen
struct A: View { var body: some View { Text("x").allowsTightening(true) } }
