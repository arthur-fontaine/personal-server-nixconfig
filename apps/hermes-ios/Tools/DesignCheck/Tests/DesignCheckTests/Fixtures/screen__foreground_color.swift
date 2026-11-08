// expect: styling-in-screen raw-color
struct A: View { var body: some View { Text("x").foregroundStyle(Color(red: 1, green: 0.5, blue: 0)) } }
