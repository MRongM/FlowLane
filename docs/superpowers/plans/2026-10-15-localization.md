# FlowLane Localization Implementation Plan

**Goal:** Ship 11-language UI with system-following and persistent manual selection.

**Architecture:** Shared localized message values + standard localized resource tables; one observable language preference reused by main window, sheets, commands and Settings. Network behavior and credentials remain independent.

- [x] Add failing tests for locale resolution, persistence, catalog completeness and safe interpolation; implement AppLanguage, LanguagePreference, LanguagePreferences and Localization/LocalizedMessage.
- [x] Localize Interface table in en/zh-Hans and translate the nine other confirmed languages with identical keys/placeholders.
- [x] Migrate application-owned runtime/errors/helper status to keyed messages; preserve old Codable status fields and request restrictions. Add runtime tables for all eleven languages and protocol tests.
- [x] Wire LanguageSettings into views, settings scene/tab, AppKit picker captions, menus and forms; add automatic system refresh and RTL with LTR technical fields. Verify no runtime/controller reset on language changes.
- [x] Add tests and locale-aware smoke modes, audit all resources and bundled lookup location; build/sign/package and inspect representative language screenshots.
- [ ] Independent review, update README/verification, commit/push existing feature branch and update draft PR. Replace local app while preserving user configuration and current language choice; do not activate or stop networking for language changes.
