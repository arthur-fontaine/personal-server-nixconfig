// expect:
enum Metric { static let hitTarget: CGFloat = 44 }
struct T: View { var body: some View { Text("x").frame(width: 44) } }
