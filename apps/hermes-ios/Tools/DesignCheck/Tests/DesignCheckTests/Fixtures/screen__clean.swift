// expect:
struct A: View {
    var body: some View {
        ChatColumn {
            VGroup(spacing: .m) {
                Text("x").textRole(.body).tone(.secondary).inset(.horizontal, .s)
                ActionRow(primary: Action(id: "a", "Allow Once", emphasis: .primary) {})
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Call") {} } }
        .overlay(alignment: .top) { Toast("Done") }
        .task { try? await Task.sleep(for: .seconds(2)) }
    }
}
