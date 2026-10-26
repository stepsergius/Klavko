import Foundation
import KlavkoCore

/// How voice input looks on screen: the panel's style, where it is and whether it shows the text heard.
struct VoiceLook: Equatable {
    enum Style: String, CaseIterable {
        case large, small, island, hidden

        var title: String {
            switch self {
            case .large: tr("Велике вікно", "Large window")
            case .small: tr("Маленьке вікно", "Small window")
            case .island: "Dynamic Island"
            case .hidden: tr("Без вікна", "No window")
            }
        }
    }

    enum Position: String, CaseIterable {
        case bottom, top

        var title: String {
            switch self {
            case .bottom: tr("Знизу", "Bottom")
            case .top: tr("Зверху", "Top")
            }
        }
    }

    var style: Style = .large
    var position: Position = .bottom
    var showText = true
}
