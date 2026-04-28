import Foundation
import OSLog

/// Minimal Sparkle-compatible updater integration.
///
/// Sparkle is the de-facto standard for macOS app updates. This module
/// manages the appcast feed URL, version comparison, and download trigger.
///
/// To fully integrate Sparkle:
///   1. Add Sparkle as an SPM dependency in project.yml
///   2. Call `SUUpdater.shared().checkForUpdates(nil)` from the menu
///   3. Host an appcast.xml at the `feedURL` below
///
/// Until Sparkle is added as a dependency, this provides the metadata
/// and a placeholder for the check-for-updates action.
@MainActor
class UpdateManager {
    static let shared = UpdateManager()
    private let logger = Logger(subsystem: "com.r-shell", category: "updater")

    /// URL to the appcast feed (hosted on GitHub Releases).
    let feedURL = URL(string: "https://github.com/asmuelle/r-shell/releases/latest/download/appcast.xml")!

    /// Current app version from Info.plist.
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Current build number.
    var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    private init() {}

    /// Check for updates manually (menu item action).
    func checkForUpdates() {
        logger.info("Checking for updates (feed: \(self.feedURL))")

        // Once Sparkle is linked:
        //   SUUpdater.shared().feedURL = feedURL
        //   SUUpdater.shared().checkForUpdates(nil)

        // Placeholder: log the current version
        logger.info("Current version: \(self.currentVersion) (build \(self.currentBuild))")
    }

    // MARK: - Appcast generation helper

    /// Generate the appcast XML for a new release.
    /// Called by the CI/release script, not at runtime.
    static func generateAppcast(version: String, build: String, downloadURL: String, size: UInt64) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
                <title>R-Shell Changelog</title>
                <item>
                    <title>Version \(version)</title>
                    <sparkle:version>\(build)</sparkle:version>
                    <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
                    <enclosure url="\(downloadURL)"
                               length="\(size)"
                               type="application/octet-stream"
                               sparkle:edSignature=""/>
                    <description><![CDATA[
                        <h2>R-Shell \(version)</h2>
                        <p>See the full changelog on GitHub.</p>
                    ]]></description>
                </item>
            </channel>
        </rss>
        """
    }
}
