import Foundation

/// json-render's `Icon` names Lucide icons (https://lucide.dev/icons, PascalCase or kebab-case);
/// the app draws SF Symbols. The common ones map to their closest symbol, anything else to a
/// neutral one. `SymbolTests` checks every symbol here exists.
public enum LucideSymbols {
    public static let fallback = "circle.dashed"

    public static func symbol(for name: String) -> String {
        table[normalized(name)] ?? fallback
    }

    /// "CloudRain", "cloud-rain", "cloud_rain" → "cloudrain".
    static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Lucide's name split into words, for VoiceOver ("CloudRain" → "cloud rain").
    public static func spoken(_ name: String) -> String {
        var words: [String] = []
        var current = ""
        for c in name {
            if c == "-" || c == "_" || c == " " {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else if c.isUppercase, !current.isEmpty {
                words.append(current)
                current = String(c)
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ").lowercased()
    }

    static let table: [String: String] = [
        // Weather
        "sun": "sun.max", "moon": "moon", "cloud": "cloud", "cloudy": "cloud", "cloudrain": "cloud.rain",
        "cloudsnow": "cloud.snow", "clouddrizzle": "cloud.drizzle", "cloudlightning": "cloud.bolt",
        "cloudfog": "cloud.fog", "cloudsun": "cloud.sun", "cloudmoon": "cloud.moon", "cloudhail": "cloud.hail",
        "snowflake": "snowflake", "wind": "wind", "tornado": "tornado", "droplet": "drop", "droplets": "humidity",
        "thermometer": "thermometer.medium", "thermometersun": "thermometer.sun", "umbrella": "umbrella",
        "sunrise": "sunrise", "sunset": "sunset", "rainbow": "rainbow", "waves": "water.waves",
        // Places and time
        "mappin": "mappin.and.ellipse", "map": "map", "navigation": "location.north", "compass": "safari",
        "globe": "globe", "calendar": "calendar", "calendardays": "calendar", "clock": "clock", "timer": "timer",
        "alarmclock": "alarm", "hourglass": "hourglass", "history": "clock.arrow.circlepath",
        "home": "house", "house": "house", "building": "building.2", "building2": "building.2", "mountain": "mountain.2",
        "plane": "airplane", "car": "car", "bus": "bus", "train": "tram", "trainfront": "tram", "bike": "bicycle",
        "ship": "ferry", "truck": "truck.box", "fuel": "fuelpump", "bed": "bed.double",
        // Status
        "check": "checkmark", "x": "xmark", "checkcircle": "checkmark.circle", "circlecheck": "checkmark.circle",
        "checkcircle2": "checkmark.circle", "circlecheckbig": "checkmark.circle", "xcircle": "xmark.circle",
        "circlex": "xmark.circle", "alerttriangle": "exclamationmark.triangle", "trianglealert": "exclamationmark.triangle",
        "alertcircle": "exclamationmark.circle", "circlealert": "exclamationmark.circle", "info": "info.circle",
        "helpcircle": "questionmark.circle", "circlehelp": "questionmark.circle", "ban": "nosign",
        "loader": "progress.indicator", "power": "power",
        // Charts and numbers
        "trendingup": "chart.line.uptrend.xyaxis", "trendingdown": "chart.line.downtrend.xyaxis",
        "barchart": "chart.bar", "barchart2": "chart.bar", "barchart3": "chart.bar", "chartbar": "chart.bar",
        "chartcolumn": "chart.bar", "linechart": "chart.xyaxis.line", "chartline": "chart.xyaxis.line",
        "piechart": "chart.pie", "chartpie": "chart.pie", "activity": "waveform.path.ecg", "gauge": "gauge.medium",
        "percent": "percent", "hash": "number", "sigma": "sum", "calculator": "plus.forwardslash.minus",
        // Things
        "zap": "bolt", "battery": "battery.75percent", "batterycharging": "battery.100percent.bolt",
        "batterylow": "battery.25percent", "cpu": "cpu", "harddrive": "internaldrive", "server": "server.rack",
        "database": "cylinder.split.1x2", "wifi": "wifi", "bluetooth": "dot.radiowaves.left.and.right",
        "smartphone": "iphone", "laptop": "laptopcomputer", "monitor": "display", "tv": "tv", "printer": "printer",
        "camera": "camera", "image": "photo", "film": "film", "music": "music.note", "headphones": "headphones",
        "mic": "mic", "volume2": "speaker.wave.2", "play": "play", "pause": "pause", "lightbulb": "lightbulb",
        "lamp": "lamp.desk", "plug": "powerplug", "key": "key", "lock": "lock", "unlock": "lock.open",
        "lockopen": "lock.open", "shield": "shield", "shieldcheck": "checkmark.shield", "eye": "eye",
        "eyeoff": "eye.slash", "gift": "gift", "coffee": "cup.and.saucer", "utensils": "fork.knife",
        "pizza": "fork.knife", "wine": "wineglass", "book": "book", "bookopen": "book", "graduationcap": "graduationcap",
        "briefcase": "briefcase", "package": "shippingbox", "shoppingcart": "cart", "shoppingbag": "bag",
        "creditcard": "creditcard", "wallet": "wallet.bifold", "dollarsign": "dollarsign", "euro": "eurosign",
        "banknote": "banknote", "piggybank": "banknote", "receipt": "receipt", "flag": "flag", "tag": "tag",
        "bookmark": "bookmark", "award": "rosette", "trophy": "trophy", "medal": "medal", "star": "star",
        "heart": "heart", "sparkles": "sparkles", "flame": "flame", "leaf": "leaf", "trees": "tree",
        "flower": "camera.macro", "dumbbell": "dumbbell", "pill": "pills", "stethoscope": "stethoscope",
        "dog": "dog", "cat": "cat", "baby": "figure.and.child.holdinghands",
        // People and messages
        "user": "person", "users": "person.2", "usercheck": "person.crop.circle.badge.checkmark", "userplus": "person.badge.plus",
        "mail": "envelope", "inbox": "tray", "send": "paperplane", "messagecircle": "message", "messagesquare": "message",
        "phone": "phone", "video": "video", "bell": "bell", "belloff": "bell.slash", "atsign": "at",
        // Actions
        "settings": "gearshape", "search": "magnifyingglass", "filter": "line.3.horizontal.decrease",
        "download": "arrow.down.circle", "upload": "arrow.up.circle", "externallink": "arrow.up.right.square",
        "link": "link", "share": "square.and.arrow.up", "share2": "square.and.arrow.up", "copy": "doc.on.doc",
        "arrowright": "arrow.right", "arrowleft": "arrow.left", "arrowup": "arrow.up", "arrowdown": "arrow.down",
        "arrowupright": "arrow.up.right", "arrowdownright": "arrow.down.right", "chevronright": "chevron.right",
        "chevronleft": "chevron.left", "chevronup": "chevron.up", "chevrondown": "chevron.down",
        "refreshcw": "arrow.clockwise", "rotatecw": "arrow.clockwise", "repeat": "repeat", "plus": "plus",
        "minus": "minus", "pencil": "pencil", "edit": "pencil", "trash": "trash", "trash2": "trash",
        "file": "doc", "filetext": "doc.text", "folder": "folder", "clipboard": "clipboard", "list": "list.bullet",
        "listchecks": "checklist", "layoutgrid": "square.grid.2x2", "terminal": "terminal",
        "code": "chevron.left.forwardslash.chevron.right", "gitbranch": "arrow.triangle.branch",
        "github": "chevron.left.forwardslash.chevron.right",
    ]
}
