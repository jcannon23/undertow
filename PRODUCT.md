# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

(macOS only. Recorded as `adaptive` because the schema has no `macos` value: Undertow follows
macOS conventions throughout, with no web or mobile surface.)

## Users
People who write all day on a Mac across many apps: email, chat, documents, prompts to AI tools.
The first user is its author, on two Macs (16 GB and 24 GB Apple Silicon). Confirmed 2026-11-10:
it is intended to be released as a product, not kept as a private tool.

## Product Purpose
Undertow predicts the next words while you type, in any Mac app, and shows them as grey text at
the caret. Tab takes a word. Success is typing roughly half as many keystrokes without the
writing sounding any less like the writer.

## Positioning
Everything runs on the Mac: a local language model, no account, nothing typed leaves the machine.
It continues the writer's sentence rather than writing for them, and it learns their names,
jargon and habits from what they actually type.

## Operating Context
A menu-bar app with no main window. It is felt, not looked at: the surfaces a person sees are the
grey suggestion inline in other apps' text fields, a menu-bar glyph, a settings window, the app
icon in Finder/Dock/Settings, and update dialogs.

## Capabilities and Constraints
- Inline completion at end of line; Tab = next word, Shift-Tab = whole suggestion, Option-Tab =
  three alternative words, Esc = dismiss.
- Inline typo fix; personal language model (vocabulary, word pairs, accept/reject feedback).
- Local Gemma model via llama.cpp; Apple Silicon only; needs Accessibility permission.
- Password fields and password managers are never read.
- Undecided: pricing, website, licence.

## Brand Commitments
- Name: Undertow.
- The icon must not read as AI-generated (2026-11-10). Named failures of the first attempt: its
  colour choice (blue-to-teal), gradient and glow, abstract pill shapes, and no sense of material
  or a hand.

## Evidence on Hand
- Simulated-typing benchmark (Tools/bench): 48.1% of keystrokes saved with Gemma 4 E2B. The test
  passages were written by the developer's assistant, so real-world numbers will be lower.
- No customers, testimonials, press or pricing exist. Do not invent any.

## Product Principles
1. The writer's words, sooner. Never a different voice.
2. Disappear into the Mac: match the host app's font, baseline and manners.
3. Private by construction, not by policy.
4. Wrong suggestions cost attention; show less when unsure.
