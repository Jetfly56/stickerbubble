# ThumbDrop

macOS bubble sticker sender (SwiftPM). Sticker exchange happens over **Matrix** — sign in to any Matrix homeserver (matrix.org, Beeper / matrix.beeper.com, or self-hosted), add a peer by their MXID, and stickers flow through a private 1-1 DM room. Any Matrix client (Element, Element X, FluffyChat, Beeper) signed in on iOS or elsewhere shares the same conversation.

- Run the app: `swift run` from this folder (macOS 13+).
- Sign in via **Account & sync…** in the menu (or the person button on the bubble), pick a homeserver, and add contacts by MXID.
- Unencrypted rooms only for now — E2EE is not yet implemented.
