"""Events in the user's life (a WhatsApp message, an iMessage...) that Hermes
may want to propose an action about. Sources feed one pipeline: dedupe, drop
what is old (replays), batch a burst per chat, ask a small local model whether
it may call for the user (triage), and post what passes to Hermes' webhook
route, which drafts the proposal and sends it to the main chat."""
