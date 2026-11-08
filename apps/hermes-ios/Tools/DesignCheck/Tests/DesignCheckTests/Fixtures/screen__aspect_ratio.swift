// expect: layout-literal
struct A: View { var body: some View { Image("pet").resizable().aspectRatio(1.3, contentMode: .fill) } }
