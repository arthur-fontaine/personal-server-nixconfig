// expect: styling-in-screen glass-in-content
struct A: View { var body: some View { Button("x") {}.buttonStyle(.glass) } }
