import AppKit
import KlavkoCore
import SwiftUI

/// Google Docs draws its text itself and shows it to other apps only with its braille support on
/// (Tools → Accessibility). Klavko notices a document without it and offers to turn it on: one shortcut, ⌘⌥H,
/// which Docs remembers for the Google account.
@MainActor
enum GoogleDocsAccess {
    enum State: Equatable {
        /// Not a Google Docs document, or its text is there.
        case fine
        /// Screen reader support on, braille support off: the text is hidden.
        case brailleOff
        /// Both off, or braille on in an empty document (Docs shows the same then).
        case maybeOff
    }

    /// What the focused element of `app` says about Google Docs.
    static func state(of app: NSRunningApplication) -> State {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        guard let focused = element(appElement, kAXFocusedUIElementAttribute), documentPath(from: focused) != nil else {
            return .fine
        }
        let role = string(focused, kAXRoleAttribute)
        if role == kAXGroupRole, string(focused, kAXSubroleAttribute) == "AXEmptyGroup" { return .brailleOff }
        if role == kAXTextAreaRole, (string(focused, kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "\u{200B}\u{FEFF}"))).isEmpty { return .maybeOff }
        return .fine
    }

    /// The window of `app` with the document, for placing the offer.
    static func windowFrame(of app: NSRunningApplication) -> NSRect? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = element(appElement, kAXFocusedWindowAttribute),
              let positionValue = value(window, kAXPositionAttribute), let sizeValue = value(window, kAXSizeAttribute),
              let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return NSRect(x: position.x, y: mainHeight - position.y - size.height, width: size.width, height: size.height)
    }

    /// The document's address, to offer once a document.
    static func documentPath(of app: NSRunningApplication) -> String? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return element(appElement, kAXFocusedUIElementAttribute).flatMap(documentPath(from:))
    }

    /// Docs' shortcut for braille support (it turns screen reader support on with it). The H key wherever it is
    /// in the layout: Docs goes by the key.
    static func pressBrailleShortcut() {
        TextInjector.pressKey(4, flags: [.maskCommand, .maskAlternate])
    }

    /// The address of the Google Docs document `focused` is in; nil outside one.
    private static func documentPath(from focused: AXUIElement) -> String? {
        var element = focused
        for _ in 0..<20 {
            // The typing goes to a frame of its own (about:blank) inside the document's page.
            if string(element, kAXRoleAttribute) == "AXWebArea", let url = value(element, "AXURL") as? URL, url.host() != nil {
                return url.host() == "docs.google.com" && url.path().hasPrefix("/document/") ? url.path() : nil
            }
            guard let parent = Self.element(element, kAXParentAttribute) else { return nil }
            element = parent
        }
        return nil
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

/// The offer over the document: what's needed and a button that turns it on.
@MainActor
final class GoogleDocsOffer {
    enum Step { case offer, failed }

    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func show(_ step: Step, in window: NSRect, onTurnOn: @escaping () -> Void, onLater: @escaping () -> Void) {
        close()
        let view = FirstClickHostingView(rootView: GoogleDocsOfferView(step: step, onTurnOn: onTurnOn, onLater: onLater))
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.contentView = view
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let size = view.fittingSize
        panel.setContentSize(size)
        // Top right of the document, under the toolbars.
        panel.setFrameOrigin(NSPoint(x: window.maxX - size.width - 24, y: window.maxY - size.height - 150))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct GoogleDocsOfferView: View {
    let step: GoogleDocsOffer.Step
    let onTurnOn: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(Color.accentColor)
                Text(tr("Перевірка правопису в Google Docs", "Spell check in Google Docs"))
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(step == .offer
                 ? tr("Щоб Klavko бачив текст документа, у Google Docs потрібна підтримка дисплея Брайля. Klavko може ввімкнути її сам (⌘⌥H). Google запам’ятає це для вашого акаунта; вимкнути можна там само.",
                      "For Klavko to see the document’s text, Google Docs needs braille support on. Klavko can turn it on for you (⌘⌥H). Google remembers it for your account; you can turn it off the same way.")
                 : tr("Не вийшло. Увімкніть у Google Docs: Інструменти → Доступність → «Увімкнути програму зчитування з екрана» і «Увімкнути підтримку дисплея Брайля».",
                      "That didn’t work. Turn it on in Google Docs: Tools → Accessibility → “Turn on screen reader support” and “Turn on braille support”."))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if step == .offer {
                    Button(action: onTurnOn) {
                        Text(tr("Увімкнути", "Turn On"))
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                Button(step == .offer ? tr("Не зараз", "Not Now") : tr("Зрозуміло", "Got It"), action: onLater)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
    }
}
