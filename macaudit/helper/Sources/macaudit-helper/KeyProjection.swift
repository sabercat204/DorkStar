import Foundation

/// The Tier 1 launch-key set — must match lib/surfaces.sh surfaces_launch_keys.
let launchKeySet: Set<String> = [
    "Label", "Program", "ProgramArguments", "RunAtLoad",
    "KeepAlive", "WatchPaths", "StartInterval", "StartCalendarInterval",
    "MachServices", "Sockets", "UserName", "GroupName"
]

/// The Tier 2 security-critical key map — must match lib/surfaces.sh
/// surfaces_security_keys_for_domain.
let securityKeyMap: [String: Set<String>] = [
    "com.apple.loginwindow": [
        "LoginHook", "LogoutHook", "autoLoginUser",
        "SHOWFULLNAME", "DisableConsoleAccess"
    ],
    "com.apple.screensaver": [
        "askForPassword", "askForPasswordDelay", "idleTime"
    ],
    "com.apple.SoftwareUpdate": [
        "AutomaticCheckEnabled", "AutomaticDownload",
        "AutomaticallyInstallMacOSUpdates", "CriticalUpdateInstall"
    ],
    "com.apple.alf": [
        "globalstate", "allowsignedenabled",
        "stealthenabled", "loggingenabled"
    ],
    ".GlobalPreferences": [
        "com.apple.security.firewall.enable",
        "AppleShowAllExtensions", "NSQuitAlwaysKeepsWindows"
    ],
    "NSGlobalDomain": [
        "com.apple.security.firewall.enable",
        "AppleShowAllExtensions", "NSQuitAlwaysKeepsWindows"
    ],
    "com.apple.Safari": [
        "AutoFillPasswords", "AutoOpenSafeDownloads",
        "WarnAboutFraudulentWebsites"
    ]
]

/// Filter a plist dictionary to only the keys in the given set.
/// Returns nil if the plist top-level is not a dictionary.
func projectKeys(_ plistObj: Any, allowedKeys: Set<String>) -> [String: Any]? {
    guard let dict = plistObj as? [String: Any] else { return nil }
    return dict.filter { allowedKeys.contains($0.key) }
}
