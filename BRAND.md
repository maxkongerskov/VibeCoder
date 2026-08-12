# BRAND — NEW DAY

> Single source of truth for visual identity and voice. The app, website, emails, documentation, support replies, and social posts all draw from here. When any surface drifts from this doc, this doc wins.

---

## 1. Brand positioning

### 1.1 One-sentence brand

**AgentOS — the local-first coding agent for developers who own their work.**

### 1.2 What we stand for

Privacy, autonomy, craft. We believe code is private, that your tools should run on your own hardware, and that AI assistance shouldn't require a subscription. We respect users' intelligence and their ownership of their work.

### 1.3 What we're not

We're not the cheapest. We're not the loudest. We're not for everyone. We're for the developer who's already running LM Studio or Ollama on their Mac and wants the agent loop on top — built native, polished, paid for once.

### 1.4 Competitive voice

| Competitor | Their voice | Ours |
|---|---|---|
| **Cursor** | Fast, enthusiastic, AI-forward | Calm, deliberate, craftspeople |
| **Claude Code** | Anthropic-clean, sophisticated | Local-first, no cloud asterisk |
| **LM Studio** | Technical, dense, power-user | Refined version of the same audience |
| **Ollama** | Open-source friendly, command-line | Polished, GUI-first, paid |
| **Continue.dev** | Plugin-y, integrative | Standalone, native, with its own surface |

---

## 2. The voice

### 2.1 Three principles

1. **Precision over enthusiasm.** "Streams at 47 tok/s" beats "Lightning-fast streaming!" Numbers, specifics, concrete claims.
2. **Respectful, not deferential.** Talk to developers like developers. Don't dumb down. Don't grovel. Don't apologize for things that aren't problems.
3. **Calm, even when explaining hard things.** Errors, edge cases, license expiry — all delivered without alarm. The tone is "a senior engineer telling you what's up," not "an assistant trying to please you."

### 2.2 Do / Don't

| Do | Don't |
|---|---|
| "Streams 47 tok/s on Qwen2.5-Coder 32B." | "Blazing-fast streaming you'll love!" |
| "Your trial expires Friday." | "Hi! Just a friendly reminder that your trial is ending soon ❤️" |
| "Couldn't reach the model server on :1234. Is LM Studio running?" | "Oops! Something went wrong." |
| "Patch applied. Build passed." | "🎉 Awesome! Your changes have been applied!" |
| "Agent stalled — same tool 3× in a row." | "I'm sorry, I seem to be having trouble." |
| "$430 one-time." | "Affordable lifetime access for the price of a few coffees per month!" |
| "Runs offline." | "Privacy-first AI you can trust." |
| "Pick a model." | "Let's get you set up with the perfect AI assistant!" |

### 2.3 Sentence patterns

**Lead with the noun, not the action.**
- "Worktree merged into main." ✓
- "Successfully merged worktree into main." ✗

**Numbers beat adjectives.**
- "4-second cold launch." ✓
- "Fast cold launch." ✗

**Active voice for actions, passive only for state.**
- "The agent edits files. Files are tracked by git." ✓
- "Files are edited by the agent. Git tracks files." ✗

**No exclamation marks in product copy.** Reserved for genuine alarm (security, data loss). Even there, prefer a calm declarative.

### 2.4 Emoji policy

- **Product UI:** none. Ever.
- **Documentation:** allowed sparingly as section icons; never decoratively.
- **Marketing site:** zero on the homepage. Allowed in changelog if relevant (e.g., 🔒 for security notes, ⚡ for perf).
- **Support replies:** matched to the customer's tone. If they use them, use one back. Otherwise don't.
- **Social media:** allowed for clarity (single emoji per post). Avoid stacks.

### 2.5 Words we use

| Concept | Use | Don't use |
|---|---|---|
| The user's machine | "your Mac" | "your device" |
| AI model | "model" or "Qwen 32B" | "AI" / "the AI" / "the assistant" |
| The product | "AgentOS" or "NEW DAY" | "the app" (in marketing) / "our solution" |
| Privacy | "runs offline" / "nothing leaves your Mac" | "secure" / "private" (vague) |
| Performance | "47 tok/s on Qwen 32B" | "fast" / "blazing" / "lightning" |
| The agent loop | "agent" or "loop" | "AI assistant" / "smart helper" |
| Errors | "X failed: <specific reason>" | "Oops" / "Something went wrong" |
| Payment | "license" / "one-time" | "subscription" / "purchase" / "buy" (in checkout flow) |
| Updates | "update" | "upgrade" |
| Models in catalog | "tested model configs" / "starter model" | "recommended for you" / "suggested" / "best pick for your Mac" |
| Hardware fit | "fits in 24 GB" / "needs 48 GB" | "perfect for your Mac" / "optimized for your hardware" |

### 2.6 Capitalization

- Product name: **AgentOS** (one word, A and OS caps). The full form is **AgentOS — NEW DAY** with em dash. Short form just **AgentOS**.
- "NEW DAY" is all caps.
- Backend names: **MLX**, **GGUF**, **LM Studio** (space), **EXO** (all caps), **llama.cpp** (lowercase, no caps).
- Features: **Worktree mode**, **Safe Mode**, **BuildGuard**, **LocalAPIServer** (camel for code-derived names; Title Case for user-facing features).

---

## 3. Visual identity

### 3.1 Logo system

Three forms, used contextually:

**Wordmark** — the primary mark.
```
AgentOS
```
- Typeface: Geist Sans
- Weight: Semibold
- Tracking: −1%
- Size: scales freely; minimum 16 pt for legibility
- Color: `fg.primary` on `bg.canvas` (light) or `fg.primary` on `bg.canvas` (dark) — high contrast both modes
- Never set in: italic, all caps, anything other than Geist Sans

**Wordmark + tag** — used in the welcome screen, marketing hero.
```
AgentOS
— NEW DAY
```
- "NEW DAY" set in Geist Sans Medium, 60% of wordmark size, `fg.secondary`
- Em dash separator, full size, `fg.tertiary`

**Symbol** — for app icon, favicon, contexts too small for the wordmark.

```
        ◐
     (filled-half circle, Azure accent, on neutral background)
```

Concept: a half-filled circle (or "loop in progress") referring to the agent loop. The half-filled state suggests iteration without completion — the agent is always working, never frozen.

The symbol uses:
- Background: warm-neutral canvas (`#FCFBF8` light / `#181715` dark)
- Foreground: Azure accent (`#2563EB`) for the filled half
- Stroke: 0 (filled shape, no outline)
- Proportions: 60% fill ratio; the filled half "leads" — visually weighted bottom-right

**App icon brief (for designer commission or AI generation):**
- 1024 × 1024 master, rendered into macOS standard icon size variants
- Rounded square (system corner radius for macOS icons — automatic via Xcode AppIcon)
- Background: subtle warm gradient from `#FCFBF8` to `#F4F2EC` (light) or `#22201D` to `#181715` (dark variant)
- The half-circle symbol centered, sized at 65% of the icon canvas
- No drop shadow, no inner glow, no embossing — flat, modern
- Two variants required: light-mode and dark-mode (macOS switches automatically)

### 3.2 Brand color (recap from UI_DESIGN §2.3)

Primary accent: **Cobalt** — `#3385F2`, hardcoded (not system .accentColor) so the brand stays consistent regardless of the user's macOS accent setting. Paired with **Ember** orange (`#E75D3C`) for the send button affordance.

Adopted from DEV PLAN's proven palette during UI Iteration 2 (2026-06-02). Replaces the iteration-1 Azure (`#2563EB`) — slightly less saturated, reads warmer when paired with the Ember orange, more cohesive with the three-tone Claude.ai-style surfaces.

Used for:
- Wordmark accent in certain contexts (e.g., the dot between Agent and OS on splash, optional)
- App icon symbol
- Marketing site CTAs
- Email link colors
- Documentation accent

Never used decoratively. Always functional or for the brand mark itself.

### 3.3 Typography (recap from UI_DESIGN §2.1)

- **Geist Sans** — UI body, marketing headings, email body
- **Geist Mono** — code samples, model names, technical data, file paths

Marketing exception: hero headlines may use Geist Sans at display sizes (60–80 pt) for landing pages. Body remains 14–16 pt for readability.

### 3.4 Photography & imagery

- **No stock photos.** Ever. Stock photography in dev tool marketing is instantly trust-eroding.
- **No 3D-rendered abstract shapes.** Generic "AI/tech" visuals.
- **Product screenshots are the primary imagery.** Real UI, real models, real conversations. Anonymized where needed.
- **Illustration:** if needed, custom commissioned line work that matches the wordmark's geometric character. Never clip art.

### 3.5 Iconography (recap from UI_DESIGN §2.6)

SF Symbols only. Same vocabulary across app, website, and documentation. Custom raster icons are forbidden.

---

## 4. Content rules

### 4.1 Product copy

- Maximum sentence length in UI: 12 words. Settings descriptions can go to 20 if needed for clarity.
- Button labels: 1–3 words. Verbs preferred ("Send", "Reload now", "Buy a license").
- Error messages: state the problem, suggest the fix, in that order. One sentence each.
- Empty states: state what's missing, point to the action that fills it.

### 4.2 Marketing copy

- Homepage hero: one sentence, the brand positioning (§1.1) or close variant
- Feature headlines: noun-first, technical, specific (e.g., "Apple Silicon MLX. In process." not "Lightning Fast on Apple Silicon!")
- Body copy: 14–16 pt Geist Sans, 1.6 line height, paragraphs of 2–4 sentences max
- Bullet lists allowed for capability enumeration only — never as a substitute for prose explanation

### 4.3 Documentation

- Always lead with what the reader will accomplish, not what the feature is
- Code blocks: Geist Mono, syntax-highlighted, copy button
- Screenshots: real, current, dark mode shown by default (it's the "developer aesthetic")
- Procedural docs: numbered steps with imperative verbs

### 4.4 Email

- Subject lines: max 50 characters, declarative, no clickbait
- Body: 2–4 short paragraphs, no fancy templates, plain text-ish with one accent link
- Signed: "— Max, AgentOS" (founder-personal, not corporate)
- No tracking pixels. Privacy is the brand.

### 4.5 Support replies

- First line: acknowledge what they're trying to do
- Second line: the answer or the next step
- Third line (optional): the why
- Sign with first name only

---

## 5. The asset list

Everything that needs to exist before launch. Tracked here; production status logged in §7.

| Asset | Format | Notes | Status |
|---|---|---|---|
| App icon (light) | 1024² .png + .iconset | Per §3.1 brief | Not started |
| App icon (dark) | 1024² .png + .iconset | Per §3.1 brief | Not started |
| Wordmark SVG | .svg | Geist Sans Semibold | Not started |
| Symbol SVG | .svg | Half-filled circle, Azure | Not started |
| Favicon | .ico + .png 32² + .png 192² | Symbol simplified | Not started |
| Social card | 1200 × 630 .png | Wordmark + tagline + symbol | Not started |
| Product Hunt thumbnail | 240 × 240 .png | Symbol on warm bg | Not started |
| App Store category artwork | n/a (not on App Store) | — | N/A |
| Marketing hero screenshot | 2880 × 1800 .png | Real product, dark mode | Not started |
| Marketing feature screenshots × 5 | 2880 × 1800 .png each | Worktree, MLX, agent, BuildGuard, Xcode Intelligence | Not started |
| Demo video | 90 sec .mp4 | See LAUNCH.md §6 | Not started |
| Email header SVG | 600 × 80 .svg | Wordmark in Azure | Not started |
| Twitter/X header | 1500 × 500 .png | Wordmark + tagline | Not started |
| README banner | 1280 × 320 .png | For GitHub README if we add one | Not started |

Total assets to produce: **~15 visual assets + 1 video.** Designer estimate: 1–2 weeks of part-time work, or 3–4 days full-time. Could be commissioned via Fiverr/99designs/Dribbble for ~$500–1500 total, or AI-generated (Midjourney for asset directions, then manual cleanup) for closer to free + your time.

---

## 6. Asset production guidance

### 6.1 If hiring a designer

Send them this BRAND.md + UI_DESIGN.md §2.3 (color) + a Figma link with the 8-pt spacing grid. Ask them to deliver an icon, wordmark, and symbol SVG as the first deliverable. Approve those before they start on marketing assets. Estimated cost: $800–2000 for a competent freelancer in 1–2 weeks.

### 6.2 If self-producing

App icon is the highest-leverage asset; spend disproportionate care here. The icon shows in:
- Dock (everyone sees it daily)
- Spotlight search
- macOS notification center
- App Store search results (if we ever go that route)
- Email signatures
- Social posts about the product

Use Affinity Designer or Figma for SVGs, Sketch or Figma for the app icon. Export through Apple's recommended toolchain (Xcode AppIcon catalog) for the variants.

### 6.3 AI-generated as starting point

If using Midjourney or similar for icon directions: prompt with "minimalist app icon, half-filled circle, blue accent #2563EB on warm off-white background, geometric, modern, macOS app style, square format, no text" — iterate, then hand-finish in vector. Don't ship the AI output directly; the proportions and crispness aren't there.

---

## 7. Brand decisions log

| Date | Decision | Reason |
|---|---|---|
| 2026-06-02 | Brand name: AgentOS (short) / AgentOS — NEW DAY (full) | NEW DAY differentiates v1 from DEV PLAN; AgentOS remains the family name; v2 may be "AgentOS — <next chapter>" |
| 2026-06-02 | Tagline: "Local-first coding agent for developers who own their work" | Captures both privacy and craft positioning |
| 2026-06-02 | Accent color: Azure `#2563EB` | Locked in UI_DESIGN.md §2.3 sign-off |
| 2026-06-02 | Symbol concept: half-filled circle | Refers to the agent loop in progress; abstract enough to scale |
| 2026-06-02 | No stock photos, no emoji in product UI | Trust + technical-audience signaling |

---

## 8. Sign-off

Read §1.1 (brand positioning), §2.1 (voice principles), §3.1 (logo system), §5 (asset list).

Most consequential picks here:

- **Brand positioning sentence** (§1.1) — drives all marketing copy. If you disagree, every other doc shifts.
- **Symbol concept (half-filled circle)** — alternative directions: monogram (just "A"), abstract geometric (no clear concept), wordmark-only (no symbol). Half-filled circle is my pick because it ties to "agent loop in progress" — but it's not the only valid option.
- **Asset budget** (§5) — if hiring a designer, this is ~$1500 + 2 weeks. If self-producing, ~30 hours of your time. Decision: hire or self?

Lock these and the rest is execution.
