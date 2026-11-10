<div align="center">
  <img src="Assets/TreluneMark.png" alt="Trelune logo" width="72" />
  <h1>Trelune</h1>
  <p><strong>Your creative space, from draft to publish.</strong></p>
  <p>Plan, create, and track content for your social channels in a native macOS app.</p>
  <p>
    <a href="#get-started">Get started</a> ·
    <a href="#one-workflow-for-your-channels">Explore the app</a> ·
    <a href="#channels-and-integrations">Integrations</a> ·
    <a href="#documentation">Documentation</a>
  </p>
  <p><sub>macOS 14+ &nbsp;·&nbsp; Swift 6 &nbsp;·&nbsp; In development</sub></p>
</div>

<br />

<p align="center">
  <img src="docs/images/overview-dark.png" alt="Trelune overview in dark mode" width="100%" />
</p>

## One workflow for your channels

Creating content already involves enough decisions. Trelune brings your calendar, posts, media, and metrics together in an interface made for Mac. Prepare an idea for one or several channels, tailor the details for each destination, and review everything before publishing.

<table>
  <tr>
    <td width="50%"><img src="docs/images/new-post-dark.png" alt="Choosing destinations for a new post" /></td>
    <td width="50%"><img src="docs/images/calendar-light.png" alt="Monthly content calendar" /></td>
  </tr>
  <tr>
    <td><strong>One idea, multiple destinations</strong><br />Choose your channels and tailor content and options for each one.</td>
    <td><strong>Your plans at a glance</strong><br />Organize posts on the calendar and check their date, time, and time zone.</td>
  </tr>
</table>

### From creation to follow-up

- **Prepare:** organize images and videos, build carousels, choose a cover, and reorder your media.
- **Review:** check content, privacy, conflicts, and scheduling before confirming.
- **Track:** see results and failures by channel, retry when needed, and explore metrics and recent activity.
- **Work your way:** import local media, export posts to CSV, and choose light, dark, or system appearance. The app follows your macOS language: Brazilian Portuguese or English.

## Get started

### Install

1. Download `Trelune-<version>.dmg` from [Releases](https://github.com/giovannibraaga/trelune/releases/latest). It works on Apple silicon and Intel Macs running macOS 14 Sonoma or later.
2. Open the DMG and drag **Trelune** to **Applications**.
3. On first launch, macOS warns that it cannot verify the developer because this version has not yet been notarized by Apple. Open the app once, click **OK**, go to **System Settings → Privacy & Security**, and click **Open Anyway** next to “Trelune”. The app will open normally after that. Alternatively, use Terminal: `xattr -dr com.apple.quarantine /Applications/Trelune.app`.

Use the accompanying `.sha256` file to verify the download: `shasum -a 256 Trelune-<version>.dmg`.

### Build from source

**You'll need:**

- macOS 14 Sonoma or later;
- Xcode 16 or later, with command-line tools and Swift 6;
- your own developer credentials for any channels you want to connect. Integrations are optional.

```bash
git clone https://github.com/giovannibraaga/trelune.git
cd trelune
./script/build_and_run.sh
```

The script creates `dist/Trelune.app` and opens it. To build without opening the app, use `swift build -c release`. Signing and bundle identifier options are listed in [`.env.example`](.env.example); copy it to `.env` if you need to configure them. Keep the same `BUNDLE_ID` after connecting accounts, as it also identifies Keychain items and preferences.

### Your first post

1. Under **Connections**, choose a channel and follow the [setup guide](docs/CONNECTIONS.md) to create your credentials.
2. Authorize your account in the platform's official window.
3. Create a post, select destinations, and tailor the content.
4. Review the media, privacy, and schedule. The post is sent after you confirm.

## Channels and integrations

| Channel | What you can prepare | Before connecting |
|:--|:--|:--|
| **YouTube** | Videos, title, tags, privacy, thumbnail, and metrics | Desktop OAuth and resumable uploads. |
| **Instagram** | Photos, carousels, and Reels; authorized metrics | A professional account linked to a Meta Page and media hosted at a public HTTPS URL. |
| **Facebook Pages** | Text, photo albums, and Reels; authorized metrics | Publishes to Pages you manage; permissions may require review. |
| **TikTok** | Video or photo carousel; inbox draft or direct publishing | The API and test mode may restrict formats and visibility. |
| **Threads** | Text, images, videos, and carousels | Features depend on account permissions and media configuration. |
| **X** | Text and up to four images or one GIF | This integration does not upload videos. |

Capabilities depend on approved scopes and each platform's API. See [Connections](docs/CONNECTIONS.md) and [TikTok](docs/TIKTOK.md) for details.

## Made for your space

**Local data.** Posts and preferences are stored in `~/Library/Application Support/Trelune/`; OAuth tokens and secrets are stored in macOS Keychain. You use your own credentials to connect channels.

**Flexible scheduling.** Without cloud configuration, the app must be open at the scheduled time. To publish while your Mac is off, set up publishing in your own AWS account using the [cloud guide](docs/CLOUD.md).

**Assistants, if you want them.** The optional [MCP](mcp/) server lets an authorized assistant read and manage posts. The app can also start in MCP mode with `Trelune --mcp`. Configure only the tools and permissions you want to grant.

The project does not include a hosted service or subscription plan provided by the maintainer. Do not share or commit tokens, secrets, credential files, or private data. If a credential is exposed, revoke it with the provider and create a new one.

## Documentation

| Guide | What it's for |
|:--|:--|
| [Connections](docs/CONNECTIONS.md) | Set up accounts and credentials for each channel. |
| [TikTok](docs/TIKTOK.md) | Learn about the TikTok integration. |
| [Cloud](docs/CLOUD.md) | Configure media hosting and publishing in your AWS account. |
| [MCP](mcp/) | Set up the server for assistants. |

## Development

```bash
swift build
swift test
```

To create an installer:

```bash
VERSION=1.0.0 ./script/release.sh
```

The script creates `dist/release/Trelune-<version>.dmg` with a universal app for Apple silicon and Intel. With a **Developer ID Application** certificate in Keychain, it signs the app with the hardened runtime. With `NOTARY_PROFILE` (a profile created by `xcrun notarytool store-credentials`), it also notarizes the DMG, removing the first-launch warning.

The app code lives in `Sources/Trelune/`, tests in `Tests/`, and scripts in `script/`. Issues and pull requests are welcome. When reporting a problem, include your macOS version, steps to reproduce, and affected channels, but leave out credentials and private data.

## License

Trelune is available under the [MIT License](LICENSE).

---

<div align="center">
  Made to give your ideas room to grow.<br /><br />
  <a href="https://github.com/giovannibraaga/trelune/issues">Report an issue</a> ·
  <a href="https://github.com/giovannibraaga/trelune/releases">Releases</a>
</div>
