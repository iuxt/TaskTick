# Releasing TaskTick

The release workflow supports two modes:

- With Apple credentials, releases use a **Developer ID Application**
  certificate and are notarized and stapled by Apple.
- Without Apple credentials, the workflow falls back to ad-hoc signing and
  still publishes both DMGs. Gatekeeper may require users to explicitly approve
  these builds on first launch.

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

If the secrets are incomplete, GitHub Actions selects ad-hoc mode automatically.
For a local ad-hoc build or release, pass `--ad-hoc`; notarization is skipped.
