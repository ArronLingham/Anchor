import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENTITLEMENTS = ROOT / "DynamicIsland" / "DynamicIsland.entitlements"
PROJECT = ROOT / "DynamicIsland.xcodeproj" / "project.pbxproj"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
INFO_PLIST = ROOT / "DynamicIsland" / "Info.plist"


class PrivacyConfigurationTests(unittest.TestCase):
    def test_microphone_capture_is_explicitly_entitled(self):
        # Dictation records through AVAudioEngine. Camera was entitled here
        # until Phase 1 removed the webcam subsystem; audio-input is now the
        # only capture device the app claims.
        entitlements = plistlib.loads(ENTITLEMENTS.read_bytes())

        self.assertTrue(entitlements.get("com.apple.security.device.audio-input"))

    def test_camera_entitlement_is_not_reintroduced(self):
        entitlements = plistlib.loads(ENTITLEMENTS.read_bytes())

        self.assertNotIn("com.apple.security.device.camera", entitlements)

    def test_resource_access_build_settings_match_the_entitlements(self):
        # ENABLE_RESOURCE_ACCESS_* injects entitlements at build time and
        # silently overrides the .entitlements file. The camera entitlement
        # survived the webcam removal this way, and audio-input was set to NO
        # while dictation needed the microphone — both invisible from the
        # entitlements file alone, which is what the tests above check.
        project = PROJECT.read_text()

        self.assertIn("ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = YES;", project)
        self.assertNotIn("ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = NO;", project)

        self.assertIn("ENABLE_RESOURCE_ACCESS_CAMERA = NO;", project)
        self.assertNotIn("ENABLE_RESOURCE_ACCESS_CAMERA = YES;", project)

    def test_sparkle_cannot_replace_this_build_with_upstream(self):
        # Every channel in UpdateChannel points at Ebullioscopic/Atoll's
        # appcast. The copy in /Applications self-updated from v2.2.0 to
        # upstream v2.3.3 mid-development because of it.
        info = plistlib.loads(INFO_PLIST.read_bytes())
        self.assertNotIn("SUFeedURL", info)
        self.assertFalse(info.get("SUEnableAutomaticChecks", True))

        delegate = (
            ROOT / "DynamicIsland" / "services" / "AtollUpdaterDelegate.swift"
        ).read_text()
        self.assertNotIn("feedURL.absoluteString", delegate)

    def test_notes_sync_is_authorized_for_apple_events(self):
        project = PROJECT.read_text()
        entitlements = plistlib.loads(ENTITLEMENTS.read_bytes())

        self.assertNotIn("AUTOMATION_APPLE_EVENTS = NO;", project)
        self.assertIn(
            "com.apple.Notes",
            entitlements["com.apple.security.temporary-exception.apple-events"],
        )

    def test_automation_usage_text_names_notes(self):
        project = PROJECT.read_text()

        self.assertEqual(
            2,
            project.count(
                'INFOPLIST_KEY_NSAppleEventsUsageDescription = "Atoll uses AppleScripts to control Spotify, Apple Music, and Notes.";'
            ),
        )

    def test_full_access_reminder_api_has_matching_usage_text(self):
        project = PROJECT.read_text()

        self.assertEqual(
            2,
            project.count("INFOPLIST_KEY_NSRemindersFullAccessUsageDescription ="),
        )

    def test_release_resigning_preserves_archived_entitlements(self):
        workflow = RELEASE_WORKFLOW.read_text()

        self.assertIn(
            'codesign -d --entitlements :- "$APP_PATH" > "$ENTITLEMENTS_PATH"',
            workflow,
        )
        self.assertIn('--entitlements "$ENTITLEMENTS_PATH"', workflow)
        self.assertIn(
            'FINAL_ENTITLEMENTS_PATH="$RUNNER_TEMP/${APP_NAME}-final.entitlements"',
            workflow,
        )
        self.assertIn(
            'codesign -d --entitlements :- "$APP_PATH" > "$FINAL_ENTITLEMENTS_PATH"',
            workflow,
        )
        self.assertIn(
            '/usr/libexec/PlistBuddy -c "Print :com.apple.security.device.audio-input" "$FINAL_ENTITLEMENTS_PATH" | grep -qx "true"',
            workflow,
        )
        self.assertIn(
            '/usr/libexec/PlistBuddy -c "Print :com.apple.security.automation.apple-events" "$FINAL_ENTITLEMENTS_PATH" | grep -qx "true"',
            workflow,
        )

    def test_ci_checks_the_privacy_configuration(self):
        workflow = CI_WORKFLOW.read_text()

        self.assertIn("python3 -m unittest tests.test_privacy_configuration", workflow)


if __name__ == "__main__":
    unittest.main()
