// expect: raw-font
struct A: View { var body: some View { Text("Delete 41 snapshots").lineLimit(1).minimumScaleFactor(0.5) } }
