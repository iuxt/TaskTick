# Releasing TaskTick

Public releases must be signed with a **Developer ID Application** certificate
and notarized by Apple. `scripts/release.sh` refuses to publish an ad-hoc build.

For a local release, import the certificate and either store notarization
credentials in a keychain profile:

```bash
xcrun notarytool store-credentials TaskTick-notary
DEVELOPER_ID_APPLICATION="Developer ID Application: …" \
APPLE_NOTARY_KEYCHAIN_PROFILE="TaskTick-notary" \
./scripts/release.sh 1.2.3
```

or provide `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_PASSWORD`. The GitHub
release workflow expects these repository secrets:

- `DEVELOPER_ID_CERTIFICATE_BASE64`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`

Use `--ad-hoc` only to inspect a local package. That mode skips notarization
and exits before upload.
