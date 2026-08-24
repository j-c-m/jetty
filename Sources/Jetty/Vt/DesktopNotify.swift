import Foundation
import UserNotifications

/// OSC 9 / 777 desktop notifications. Clicks do not open URLs.
public enum DesktopNotify {
    public static func install() {
        Poster.shared.install()
    }

    static func post(title: String, body: String, subtitle: String = "") {
        Poster.shared.post(title: title, body: body, subtitle: subtitle)
    }
}

private final class Poster: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Poster()

    /// `UNUserNotificationCenter.current()` aborts without a reverse-DNS bundle id
    /// (`swift run` is just `jetty`).
    static func center() -> UNUserNotificationCenter? {
        guard let id = Bundle.main.bundleIdentifier, id.contains(".") else { return nil }
        return .current()
    }

    func install() {
        guard let center = Self.center() else { return }
        center.delegate = self
    }

    func post(title: String, body: String, subtitle: String) {
        guard let center = Self.center() else { return }
        if center.delegate == nil {
            center.delegate = self
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                Poster.deliver(title: title, body: body, subtitle: subtitle)
            }
        }
    }

    static func deliver(title: String, body: String, subtitle: String) {
        guard let center = center() else { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "jetty" : title
        if !subtitle.isEmpty, subtitle != content.title {
            content.subtitle = subtitle
        }
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(req, withCompletionHandler: nil)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
