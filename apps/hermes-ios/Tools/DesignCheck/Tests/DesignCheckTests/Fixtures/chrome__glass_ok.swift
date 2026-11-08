// expect:
struct Bar: View { var body: some View { GlassEffectContainer { Text("x").glassEffect(.regular, in: Capsule()) } } }
