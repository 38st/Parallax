# Parallax for iPhone prototype

This prototype keeps website accounts in independent, persistent WebKit data
stores. It does not clone or modify third-party native applications.

## Generate and run

```bash
cd ParallaxMobile
xcodegen generate
open ParallaxMobile.xcodeproj
```

Choose an iPhone simulator or a connected iPhone, select the `ParallaxMobile`
scheme, and run. A physical device is recommended for testing camera, microphone,
file uploads, passkeys, and real sign-in behavior.

The first launch creates two Instagram spaces and two ChatGPT spaces. Signing
into one space does not share cookies or website data with the others.

## Current scope

- Persistent per-space `WKWebsiteDataStore`
- Instagram, ChatGPT, and custom website spaces
- Back, forward, reload, and start-page navigation
- Per-space sign-out/reset
- Persistent space library

Home Screen shortcuts, Face ID locks, downloads, notification handling, and
website-specific compatibility work are intentionally left for later milestones.
