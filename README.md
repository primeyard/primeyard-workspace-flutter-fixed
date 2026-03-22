
# PrimeYard Workspace Native App

This version is a native Flutter app for PrimeYard Workspace.

What changed:
- fixed the login screen so the sign-in button stays visible on phones
- added persistent staff sign-in on device
- connected the app to the existing PrimeYard Firebase backend using the project's API configuration from the uploaded workspace HTML
- uses the PrimeYard mark as the Android app icon
- keeps local fallback data if cloud sync is temporarily unavailable

Default owner login:
- Username: admin
- Password: PrimeYard2025

GitHub build:
- Upload the extracted project contents to the root of a GitHub repository
- Run the workflow in `.github/workflows/build-apk.yml`
- Download the `primeyard-workspace-flutter-apk` artifact

Note:
For the most production-ready Firebase mobile setup, it is still best to register the Android app in Firebase and generate platform config with FlutterFire CLI later.
