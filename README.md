# Convertmax iOS SDK (0.2.0)

Swift Package Manager package for the native Convertmax mobile event SDK. The public actor API covers consent, identity, track, screen, revenue observations, deep-link parameter extraction and diagnostics. Events are stored in SQLite, flushed as gzip `mobile-v1` batches, and retried on backgrounding.

## Install

Add this repository as a Swift Package dependency, then import `Convertmax`:

```swift
let sdk = Convertmax(configuration: .init(writeKey: "YOUR_WRITE_KEY", appID: "com.example.app"))
await sdk.setConsent(.granted)
await sdk.identify("account-123")
_ = await sdk.track("signup", properties: ["plan": "pro"])
```

The write key is ingestion-only. The SDK persists consent, identity, anonymous ID, session ID and queued events in an app-scoped SQLite store. `flush()` delivers queued events; `clearQueue()` intentionally discards them. Denied consent cancels delivery, clears pending events and rotates identity.

## Sample app

1. Open `samples/ios/ConvertmaxSample.xcodeproj` in Xcode (or regenerate it with `cd samples/ios && xcodegen`).
2. Select an iOS Simulator and run **ConvertmaxSample**.
3. Grant consent, then Identify / Track / Screen / Observe purchase / Flush / Reset. The write key is public and ingestion-only.

```bash
swift test
cd samples/ios && xcodegen && xcodebuild -scheme ConvertmaxSample -destination 'generic/platform=iOS Simulator' build
```
