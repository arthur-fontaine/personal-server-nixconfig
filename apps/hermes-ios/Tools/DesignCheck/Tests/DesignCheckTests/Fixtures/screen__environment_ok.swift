// expect:
struct A: View { @Environment(\.dismiss) var dismiss ; var body: some View { Text("x").environment(\.locale, .current) } }
