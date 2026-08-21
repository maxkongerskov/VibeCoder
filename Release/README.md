# Release pipeline (VibeCoder)

Cut a **signed, notarised DMG** for GitHub Releases (or any host you choose).

> **Not Sparkle.** Sparkle and Sentry were removed from the package. There is
> no in-app auto-update feed. Ship versioned DMGs; users download new builds
> manually (or via your own updater later).

## Files

| File | Purpose |
|------|---------|
| `release.sh` | Archive → export Developer ID → notarise → staple → DMG |
| `ExportOptions.plist` | Developer ID export (not App Store) |
| `appcast.xml` | **Tombstone.** Not a live Sparkle feed. Not consumed by VibeCoder. Historical AgentOS items only. |

## One-time prerequisites

### 1. Developer ID Application certificate

- Xcode → Settings → Accounts → Manage Certificates → **Developer ID Application**
- Verify: `security find-identity -p codesigning -v`

### 2. notarytool keychain profile

```bash
xcrun notarytool store-credentials VibeCoder-Notary \
  --apple-id "your@apple.id" \
  --team-id YOUR_TEAM_ID \
  --password "<app-specific-password>"
```

Override profile name with `VIBECODER_NOTARY_PROFILE` if needed.

### 3. XcodeGen + clean tree

```bash
cd /path/to/VibeCoder
xcodegen generate --spec App/project.yml
# working tree should be clean before cutting a release
```

## Cutting a release

```bash
./Release/release.sh 1.0.6
```

The script:

1. Validates cert + notary profile + clean git (optional override)
2. Archives scheme **VibeCoder**
3. Exports Developer ID app, notarises, staples
4. Builds `Release/build/VibeCoder-<version>.dmg`

Then publish the DMG (example: GitHub Release):

```bash
gh release create "v1.0.6" \
  "Release/build/VibeCoder-1.0.6.dmg" \
  --title "VibeCoder 1.0.6" \
  --notes "See CHANGELOG / commit history."
```

## What this is not

- **Not** AgentOS branding or `agentos.tools` R2 upload paths
- **Not** Sparkle `sign_update` / appcast upload (removed product path)
- **Not** a substitute for code signing setup on a fresh machine

## Troubleshooting

### Notarisation rejected

```bash
xcrun notarytool log <submission-id> --keychain-profile VibeCoder-Notary
```

### Working tree dirty

Commit first, or set `VIBECODER_ALLOW_DIRTY=1` only for local smoke builds.
