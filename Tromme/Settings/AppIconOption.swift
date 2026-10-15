import SwiftUI
import StoreKit

struct AppIconOption: Identifiable {
    let id: String
    let displayName: String
    let iconName: String?         // nil = primary icon
    let previewImageName: String  // asset catalog name for the picker thumbnail
    let accentColor: Color
}

extension AppIconOption {
    static let all: [AppIconOption] = [
        AppIconOption(id: "default",   displayName: "Default",   iconName: nil,                previewImageName: "preview-default",   accentColor: Color(red: 1.0,  green: 0.40, blue: 0.00)),
        AppIconOption(id: "blue",      displayName: "Blue",      iconName: "BlueAppIcon",      previewImageName: "preview-blue",      accentColor: Color(red: 0.20, green: 0.47, blue: 0.95)),
        AppIconOption(id: "green",     displayName: "Green",     iconName: "GreenAppIcon",     previewImageName: "preview-green",     accentColor: Color(red: 0.18, green: 0.72, blue: 0.38)),
        AppIconOption(id: "purple",    displayName: "Purple",    iconName: "PurpleAppIcon",    previewImageName: "preview-purple",    accentColor: Color(red: 0.55, green: 0.25, blue: 0.90)),
        AppIconOption(id: "red",       displayName: "Red",       iconName: "RedAppIcon",       previewImageName: "preview-red",       accentColor: Color(red: 0.95, green: 0.20, blue: 0.25)),
        AppIconOption(id: "pink",      displayName: "Pink",      iconName: "PinkAppIcon",      previewImageName: "preview-pink",      accentColor: Color(red: 0.97, green: 0.30, blue: 0.65)),
        AppIconOption(id: "yellow",    displayName: "Yellow",    iconName: "YellowAppIcon",    previewImageName: "preview-yellow",    accentColor: Color(red: 0.92, green: 0.70, blue: 0.05)),
        AppIconOption(id: "white",     displayName: "White",     iconName: "WhiteAppIcon",     previewImageName: "preview-white",     accentColor: Color(.label)),
        AppIconOption(id: "black",     displayName: "Black",     iconName: "BlackAppIcon",     previewImageName: "preview-black",     accentColor: Color(.label)),
    ]

    static let premiumIconPack: [AppIconOption] = [
        AppIconOption(id: "applemusic",     displayName: "Apple Music",    iconName: "AppleMusicAppIcon",    previewImageName: "preview-applemusic",     accentColor: Color(red: 1.0, green: 0.337, blue: 0.416)),
        AppIconOption(id: "galaxy",         displayName: "Galaxy",         iconName: "GalaxyAppIcon",        previewImageName: "preview-galaxy",         accentColor: Color(red: 0.55, green: 0.08, blue: 0.85)),
        AppIconOption(id: "knocktua-dark",  displayName: "Noctua Dark",  iconName: "KnocktuaDarkAppIcon",  previewImageName: "preview-knocktua-dark",  accentColor: Color(red: 0.529, green: 0.345, blue: 0.267)),
        AppIconOption(id: "knocktua-light", displayName: "Noctua Light", iconName: "KnocktuaLightAppIcon", previewImageName: "preview-knocktua-light", accentColor: Color(red: 0.851, green: 0.792, blue: 0.639)),
        AppIconOption(id: "ltt",       displayName: "LT&T",      iconName: "LT&TAppIcon",      previewImageName: "preview-ltt",       accentColor: Color(red: 1.00, green: 0.45, blue: 0.00)),
        AppIconOption(id: "masterchief",    displayName: "Master Chief",   iconName: "MasterChiefAppIcon",   previewImageName: "preview-masterchief",    accentColor: Color(red: 0.35, green: 0.55, blue: 0.25)),
        AppIconOption(id: "murderedout",    displayName: "Murdered Out",   iconName: "MurderedOutAppIcon",   previewImageName: "preview-murderedout",    accentColor: Color(.label)),
        AppIconOption(id: "rainbow",   displayName: "Rainbow",   iconName: "RainbowAppIcon",   previewImageName: "preview-rainbow",   accentColor: Color(red: 0.93, green: 0.12, blue: 0.11)),
        AppIconOption(id: "snowwhite",      displayName: "Snow White",     iconName: "SnowWhiteAppIcon",     previewImageName: "preview-snowwhite",      accentColor: Color(.label)),
        AppIconOption(id: "trommeify",      displayName: "Trommeify",      iconName: "TrommeifyAppIcon",     previewImageName: "preview-trommeify",      accentColor: Color(red: 0.20, green: 0.83, blue: 0.15)),
        AppIconOption(id: "usa",            displayName: "USA",            iconName: "USAAppIcon",           previewImageName: "preview-usa",            accentColor: Color(red: 0.70, green: 0.10, blue: 0.15)),
        AppIconOption(id: "usfs",           displayName: "US Forest Service",           iconName: "USFSAppIcon",          previewImageName: "preview-usfs",           accentColor: Color(red: 1.00, green: 0.78, blue: 0.00)),
    ]

    static func accentColor(for iconId: String) -> Color {
        (all + premiumIconPack).first { $0.id == iconId }?.accentColor ?? all[0].accentColor
    }
}
