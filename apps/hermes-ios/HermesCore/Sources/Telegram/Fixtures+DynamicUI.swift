import Foundation

/// Dynamic UIs (§8) for the demo, the tests and the component catalogue: json-render specs as
/// Hermes' `render_ui` sends them.
public extension Fixtures {
    /// The Lisbon trip's weather: metrics, a 5-day line chart from the state, buttons that reply
    /// and open a link.
    static var weatherSpec: [String: Any] {
        [
            "root": "card",
            "state": ["forecast": [
                ["label": L("Thu"), "value": 21], ["label": L("Fri"), "value": 23], ["label": L("Sat"), "value": 24],
                ["label": L("Sun"), "value": 20], ["label": L("Mon"), "value": 19],
            ]],
            "elements": [
                "card": ["type": "Card", "props": ["title": L("Lisbon, Thursday"), "description": L("Sunny, a light breeze off the river in the evening")],
                         "children": ["now", "details", "chart", "actions"]],
                "now": ["type": "Stack", "props": ["direction": "horizontal", "gap": "md", "align": "center"], "children": ["sun", "temp"]],
                "sun": ["type": "Icon", "props": ["name": "Sun", "size": "lg"]],
                "temp": ["type": "Metric", "props": ["label": L("Afternoon"), "value": 21, "suffix": " °C",
                                                    "change": L("3° warmer than Wednesday"), "changeType": "positive"]],
                "details": ["type": "Grid", "props": ["columns": 3, "gap": "md"], "children": ["wind", "rain", "uv"]],
                "wind": ["type": "Metric", "props": ["label": L("Wind"), "value": L("14 km/h")]],
                "rain": ["type": "Metric", "props": ["label": L("Rain"), "value": "5 %"]],
                "uv": ["type": "Metric", "props": ["label": L("UV index"), "value": 6]],
                "chart": ["type": "LineGraph", "props": ["title": L("Next 5 days, °C"), "data": ["$state": "/forecast"]]],
                "actions": ["type": "Stack", "props": ["direction": "horizontal"], "children": ["source", "hourly"]],
                "hourly": ["type": "Button", "props": ["label": L("Hour by Hour"), "variant": "primary"],
                           "on": ["press": ["action": "reply", "params": ["text": L("Show me Thursday hour by hour")]]]],
                "source": ["type": "Button", "props": ["label": L("IPMA")],
                           "on": ["press": ["action": "open", "params": ["url": "https://www.ipma.pt/en/otempo/prev.localidade.hora/"]]]],
            ],
        ]
    }

    /// The Lisbon hotels as a table, a choice bound to the state, and a reply built from it.
    static var hotelsSpec: [String: Any] {
        [
            "root": "card",
            "state": ["hotel": "Casa do Largo"],
            "elements": [
                "card": ["type": "Card", "props": ["title": L("Quiet stays near Alfama"), "description": L("3 nights from the 14th")],
                         "children": ["table", "pick", "hold"]],
                "table": ["type": "Table", "props": [
                    "columns": [L("Hotel"), L("Night"), L("Rating")],
                    "rows": [["Casa do Largo", "€142", "9.1"], ["Alfama Patio", "€155", "8.8"], ["Memmo Alfama", "€159", "9.3"]],
                    "caption": L("All three are rated quiet by guests."),
                ]],
                "pick": ["type": "ButtonGroup", "props": [
                    "buttons": [["label": "Casa do Largo", "value": "Casa do Largo"], ["label": "Alfama Patio", "value": "Alfama Patio"],
                                ["label": "Memmo", "value": "Memmo Alfama"]],
                    "selected": ["$bindState": "/hotel"],
                ]],
                "hold": ["type": "Button", "props": ["label": ["$template": L("Hold ${/hotel}")], "variant": "primary"],
                         "visible": ["$state": "/hotel"],
                         "on": ["press": ["action": "reply", "params": ["text": ["$template": L("Hold ${/hotel} for 3 nights from the 14th")]]]]],
            ],
        ]
    }

    /// Every component and variant, for the catalogue page (design-rules 9.6).
    static var catalogueSpec: [String: Any] {
        [
            "root": "card",
            "state": ["tab": "usage", "disks": [["name": "Macintosh HD", "used": 41], ["name": "Backup", "used": 87]]],
            "elements": [
                "card": ["type": "Card", "props": ["title": "Server", "description": "Every component of the dynamic UI"],
                         "children": ["tabs", "sep", "badges", "alerts", "image", "text", "nested", "select", "danger"]],
                "tabs": ["type": "Tabs", "props": ["tabs": [["label": "Usage", "value": "usage"], ["label": "Disks", "value": "disks"]],
                                                   "value": ["$bindState": "/tab"]],
                         "children": ["usage", "disks"]],
                "usage": ["type": "Stack", "props": ["gap": "md"], "children": ["heading", "bars"]],
                "heading": ["type": "Heading", "props": ["text": "Model calls this week", "level": "h3"]],
                "bars": ["type": "BarGraph", "props": ["data": [["label": "Mon", "value": 412], ["label": "Tue", "value": 380],
                                                                ["label": "Wed", "value": 455], ["label": "Thu", "value": 298]]]],
                "disks": ["type": "Stack", "props": ["gap": "md"], "repeat": ["statePath": "/disks"], "children": ["disk"]],
                "disk": ["type": "Progress", "props": ["label": ["$item": "name"], "value": ["$item": "used"]]],
                "sep": ["type": "Separator"],
                "badges": ["type": "Stack", "props": ["direction": "horizontal", "gap": "sm"], "children": ["b1", "b2", "b3", "b4", "icon"]],
                "b1": ["type": "Badge", "props": ["text": "Default"]],
                "b2": ["type": "Badge", "props": ["text": "Secondary", "variant": "secondary"]],
                "b3": ["type": "Badge", "props": ["text": "Failed", "variant": "destructive"]],
                "b4": ["type": "Badge", "props": ["text": "Outline", "variant": "outline"]],
                "icon": ["type": "Icon", "props": ["name": "CloudRain", "color": "muted"]],
                "alerts": ["type": "Stack", "props": ["gap": "sm"], "children": ["a1", "a2", "a3", "a4"]],
                "a1": ["type": "Alert", "props": ["title": "Backup ran at 03:00", "type": "success"]],
                "a2": ["type": "Alert", "props": ["title": "Backup disk at 87 %", "message": "Prune old snapshots soon.", "type": "warning"]],
                "a3": ["type": "Alert", "props": ["title": "Restic failed", "message": "No space left on device.", "type": "error"]],
                "a4": ["type": "Alert", "props": ["title": "Next run tonight", "type": "info"]],
                "image": ["type": "Image", "props": ["alt": "No picture yet"]],
                "text": ["type": "Stack", "props": ["gap": "sm"], "children": ["t1", "t2", "t3", "t4"]],
                "t1": ["type": "Text", "props": ["text": "Body text with **bold** and a [link](https://example.com)."]],
                "t2": ["type": "Text", "props": ["text": "Muted text", "variant": "muted"]],
                "t3": ["type": "Text", "props": ["text": "Caption text", "variant": "caption"]],
                "t4": ["type": "Text", "props": ["text": "restic snapshots --latest 1", "variant": "code"]],
                "nested": ["type": "Card", "props": ["title": "A nested card"], "children": ["grid"]],
                "grid": ["type": "Grid", "props": ["columns": 2], "children": ["m1", "m2"]],
                "m1": ["type": "Metric", "props": ["label": "CPU", "value": "12", "suffix": " %", "change": "-3 %"]],
                "m2": ["type": "Metric", "props": ["label": "Cost", "value": "0.42", "prefix": "$", "change": "+0.05", "changeType": "negative"]],
                "select": ["type": "Select", "props": ["label": "Keep snapshots", "options": ["30 days", "90 days", "1 year"], "value": "90 days"]],
                "danger": ["type": "Stack", "props": ["direction": "horizontal"], "children": ["cancel", "prune"]],
                "cancel": ["type": "Button", "props": ["label": "Prune", "variant": "danger"],
                           "on": ["press": ["action": "reply", "params": ["text": "Prune the old snapshots"]]]],
                "prune": ["type": "Button", "props": ["label": "Later"],
                          "on": ["press": ["action": "setState", "params": ["statePath": "/tab", "value": "disks"]]]],
            ],
        ]
    }

    static func spec(_ object: [String: Any]) -> UISpec {
        UISpec.decode(try! JSONSerialization.data(withJSONObject: object))!
    }

    /// The `ui` App-topic message for a message (Bot API id), as the server posts it.
    /// The two demo messages with a UI: their text is what keys them (UIKey).
    static var hotelsText: String {
        L("Three options under €160 a night, all with good reviews for quiet:\n1. **Casa do Largo**: €142, terrace, 4 min from the tram\n2. **Alfama Patio**: €155, breakfast included\n3. **Memmo Alfama**: €159, pool, the most central\nShall I hold one?")
    }
    static var weatherText: String {
        L("Lisbon on Thursday: **21 °C** and sunny, wind 14 km/h, 5 % chance of rain. The next days: 23, 24, 20 and 19 °C.")
    }

    /// `text`: the message's, for its key (the plugin's own computation, UIKey).
    static func uiJSON(chat: TopicID, messageID: MessageID, text: String, spec: [String: Any]) -> String {
        // The plugin keys the text it sends with markdown removed: as the message reads here.
        let o: [String: Any] = ["v": 4, "type": "ui", "chat": Int(chat), "message_id": messageID,
                                "key": UIKey.of(Markdownish.parse(text).text), "spec": spec]
        return String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
    }
}
