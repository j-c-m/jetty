import UserNotifications

/// OSC 9 / 777 desktop notifications. Clicks do not open URLs.
public enum DesktopNotify {
    public static func install() {
        Poster.shared.install()
    }

    static func post(title: String, body: String) {
        Poster.shared.post(title: title, body: body)
    }
}

private final class Poster: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Poster()

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil {
            center.delegate = self
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                Poster.deliver(title: title, body: body)
            }
        }
    }

    static func deliver(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "jetty" : title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
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
