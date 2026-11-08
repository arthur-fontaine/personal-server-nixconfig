// expect: glass-in-content
struct Card: View { var body: some View { Text("x").glassEffect(.regular, in: Capsule()) } }
