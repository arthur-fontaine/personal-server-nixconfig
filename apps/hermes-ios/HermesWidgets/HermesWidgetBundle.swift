import WidgetKit
import SwiftUI
@main struct HermesWidgetBundle: WidgetBundle { var body: some Widget { EmptyWidget() } }
struct EmptyWidget: Widget { var body: some WidgetConfiguration { StaticConfiguration(kind: "x", provider: P()) { _ in Text("x") } } }
struct E: TimelineEntry { let date = Date() }
struct P: TimelineProvider { func placeholder(in c: Context) -> E { E() }; func getSnapshot(in c: Context, completion: @escaping (E) -> Void) { completion(E()) }; func getTimeline(in c: Context, completion: @escaping (Timeline<E>) -> Void) { completion(Timeline(entries: [E()], policy: .never)) } }
