# Free Windows → iPhone build path

This repo package is prepared for a free GitHub Actions macOS build, followed by signing/installing with iPASide on Windows.

## Steps
1. Create a GitHub account (free), then create a **public** repository named `BLEDOM-Halloween` (the workflow runs on GitHub's hosted macOS runner; public repos are eligible for free standard hosted runner usage under GitHub's current policy).
2. Upload the contents of this folder to the repository. Ensure `.github/workflows/build.yml` is included.
3. Open the repository → **Actions** → **Build BLEDOM Halloween IPA** → **Run workflow**. Or push to `main` to trigger a build.
4. Wait for green check. Open the completed workflow run, find **Artifacts**, download `BLEDOMHalloween-ipa`, and extract the ZIP. It contains `BLEDOMHalloween.ipa`.
5. On Windows, install iPASide from its official project site: https://ipaside.com/ . Install Apple Devices (Microsoft Store) if needed.
6. Connect iPhone by USB, unlock it, tap **Trust**. In iPASide, sign in with Apple ID (using a spare Apple ID is prudent), then drag the `.ipa` into Sideload and install.
7. On iPhone, trust the developer profile in Settings → General → VPN & Device Management. On iOS 16+, enable Developer Mode if prompted.
8. Launch app, scan, connect BLEDOM06, start orange ↔ purple.

## Apple free signing limits
- Free Apple ID signatures expire after 7 days. Re-sign/reinstall via iPASide when needed; turn on auto-refresh if available.
- Apple's free signing limit is generally 3 sideloaded apps active at once.
- Use a spare Apple ID if you prefer not to use your main Apple ID with third-party sideloading software.
- Do not enter Apple ID credentials into websites. Sign in only inside the sideloading app after verifying its source.

## Notes
- The build is unsigned; iPASide signs it for your device.
- This is a prototype; it has not yet been compiled or tested on BLEDOM06 hardware.
- It uses a known Lotus Lantern-style RGB frame but compatibility is not guaranteed until connected and tested.
