// Notify.swift: tiny notification helper for docker-lease.
//
// Why this exists: `osascript -e 'display notification ...'` has no app icon,
// so docker-lease notifications show up with the generic script icon. Posting
// through UserNotifications from inside a bundled, signed .app gives the banner
// its own icon.
//
// Contract used by bin/docker-lease.sh:
//   docker-lease-notify "message"   post a notification, exit 0 on acceptance
//   docker-lease-notify --request-authorization
//                                   ask for permission, exit 0 if granted
//
// Exit codes are the notification helper's whole interface:
//   0  request accepted by the system / authorization granted
//   1  authorization denied (request mode)
//   2  no message argument
//   3  not authorized to alert (notDetermined, denied, or alert setting off)
//   4  addNotificationRequest failed
//   5  authorization request failed with an error
//
// CAVEAT: exit 0 means the system ACCEPTED the request, not that the user saw
// anything. Focus modes, Do Not Disturb, and a disabled alert style all accept
// the request and present nothing. That is why the shell script logs failures
// but never treats "exit 0" as proof of a visible banner.

import Foundation
import UserNotifications

let bundleTitle = "docker reaper"
let exitUnauthorized: Int32 = 3

func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func die(_ message: String, _ code: Int32) -> Never {
    stderr(message)
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())

// ------------------------------------------------------------ authorize ----
// Matches the shipped binary's `--request-authorization` mode: prompt once,
// report the outcome on stdout/stderr, and let the exit code carry the result.
if args.contains("--request-authorization") {
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    var failure: String?

    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, error in
        if let error = error {
            failure = error.localizedDescription
        } else {
            granted = ok
        }
        sem.signal()
    }

    if sem.wait(timeout: .now() + 30) == .timedOut {
        die("NOTIFY: request failed: timed out", 5)
    }
    if let failure = failure {
        die("NOTIFY: request failed: \(failure)", 5)
    }
    if granted {
        // Written to stdout so an installer can branch on it, but the exit
        // code is the authoritative answer.
        print("NOTIFY: authorization granted")
        exit(0)
    }
    die("NOTIFY: authorization denied", 1)
}

// ------------------------------------------------------------ notify ------
guard let message = args.first, !message.isEmpty else {
    die("NOTIFY: no message argument", 2)
}

let center = UNUserNotificationCenter.current()

// Permission is not enough: the user can authorize notifications and still
// turn the alert style off, in which case posting succeeds and nothing shows.
// Treat "alert style is not enabled" as unauthorized so the caller falls back
// to osascript instead of silently dropping the message.
let settingsSem = DispatchSemaphore(value: 0)
var status: UNAuthorizationStatus = .notDetermined
var alertEnabled = false

center.getNotificationSettings { settings in
    status = settings.authorizationStatus
    alertEnabled = (settings.alertSetting == .enabled)
    settingsSem.signal()
}

if settingsSem.wait(timeout: .now() + 10) == .timedOut {
    die("NOTIFY: unauthorized", exitUnauthorized)
}
if status != .authorized || !alertEnabled {
    die("NOTIFY: unauthorized", exitUnauthorized)
}

let content = UNMutableNotificationContent()
content.title = bundleTitle
content.body = message
content.sound = .default

// A fresh identifier per message: no replacement of an earlier banner, and no
// dedupe if the same message fires twice.
let request = UNNotificationRequest(identifier: UUID().uuidString,
                                    content: content,
                                    trigger: nil)

let addSem = DispatchSemaphore(value: 0)
var addFailure: String?

center.add(request) { error in
    if let error = error {
        addFailure = error.localizedDescription
    }
    addSem.signal()
}

// Brief runloop: the add callback needs the process alive, but an LSUIElement
// helper should not linger. Two seconds is plenty for a local hand-off.
if addSem.wait(timeout: .now() + 2) == .timedOut {
    die("NOTIFY: add failed: timed out", 4)
}
if let addFailure = addFailure {
    die("NOTIFY: add failed: \(addFailure)", 4)
}

// Accepted, not necessarily presented. See the caveat at the top of the file.
exit(0)
