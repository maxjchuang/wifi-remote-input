# Protocol

The wire format will use versioned JSON messages over an authenticated encrypted WebSocket.

## Message envelope

```json
{
  "version": 1,
  "id": "unique-message-id",
  "type": "text.commit",
  "payload": {
    "text": "你好"
  }
}
```

## Initial message types

| Type | Purpose |
| --- | --- |
| `text.commit` | Commit Unicode text to the focused editor. |
| `key.press` | Send a named non-text key such as Enter or Backspace. |
| `key.down` / `key.up` | Represent modifiers and shortcuts when supported. |
| `pointer.move` | Move the optional accessibility cursor. |
| `pointer.button` | Press or release a pointer button. |
| `pointer.scroll` | Scroll through the accessibility service. |
| `session.ping` / `session.pong` | Check liveness and latency. |
| `error` | Return a structured, non-sensitive failure. |

## Rules

- Printable text is transported as Unicode text rather than HID keycodes.
- Message types and fields are versioned; unknown optional fields are ignored.
- A connection cannot send input until authentication completes.
- Implementations apply size and rate limits before processing input.
- Protocol errors never echo submitted text or secrets.
