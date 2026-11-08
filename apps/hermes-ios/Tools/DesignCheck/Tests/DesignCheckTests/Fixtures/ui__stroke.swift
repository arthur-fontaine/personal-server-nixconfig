// expect: stroke-or-shadow
struct Card: View { var body: some View { RoundedRectangle(cornerRadius: Radius.card).stroke(.separator) } }
