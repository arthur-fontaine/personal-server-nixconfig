// JSON lines between the sidecar and the Hermes plugin, one object per line
// on stdin/stdout (stderr is free text, for the plugin's log).
//
// Sidecar -> plugin:
//   {"type": "<event>", ...}             an event, no answer expected
//   {"type": "request", "id": n, "kind": "<kind>", ...}
//                                        a question the plugin must answer
// Plugin -> sidecar:
//   {"type": "<command>", ...}           a command (stop, grant, revoke)
//   {"type": "reply", "id": n, ...}      the answer to request n
//
// Requests are how the network policy will wait on Hermes' authorization
// (stage 2): isRequestAllowed awaits peer.request("approve", {...}).

export class Peer {
  constructor(input, output) {
    this.output = output;
    this.handlers = new Map();
    this.pending = new Map();
    this.nextId = 1;
    this.closed = false;
    this.onClose = () => {};
    let buffer = "";
    input.setEncoding("utf8");
    input.on("data", (chunk) => {
      buffer += chunk;
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline).replace(/\r$/, "");
        buffer = buffer.slice(newline + 1);
        if (line.trim()) this.#receive(line);
      }
    });
    input.on("end", () => this.#close());
    input.on("close", () => this.#close());
  }

  on(type, handler) {
    this.handlers.set(type, handler);
  }

  send(type, fields = {}) {
    if (this.closed) return;
    this.output.write(JSON.stringify({ ...fields, type }) + "\n");
  }

  // Resolves with the plugin's reply; rejects if the plugin goes away first
  // or does not answer in time (a deny, for the network policy).
  request(kind, fields = {}, { timeoutMs = 0 } = {}) {
    if (this.closed) return Promise.reject(new Error("peer closed"));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = timeoutMs > 0
        ? setTimeout(() => {
          this.pending.delete(id);
          reject(new Error(`no reply to ${kind} in ${timeoutMs} ms`));
        }, timeoutMs)
        : null;
      this.pending.set(id, { resolve, reject, timer });
      this.send("request", { ...fields, id, kind });
    });
  }

  #receive(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      process.stderr.write(`hermes-sandbox: ignoring a line that is not JSON\n`);
      return;
    }
    if (message === null || typeof message !== "object" || typeof message.type !== "string") return;
    if (message.type === "reply") {
      const waiting = this.pending.get(message.id);
      if (!waiting) return;
      this.pending.delete(message.id);
      if (waiting.timer) clearTimeout(waiting.timer);
      waiting.resolve(message);
      return;
    }
    const handler = this.handlers.get(message.type);
    if (handler) {
      Promise.resolve()
        .then(() => handler(message))
        .catch((error) => this.send("log", { level: "error", message: String(error?.message ?? error) }));
    } else {
      this.send("log", { level: "warning", message: `unknown command: ${message.type}` });
    }
  }

  #close() {
    if (this.closed) return;
    this.closed = true;
    for (const { reject, timer } of this.pending.values()) {
      if (timer) clearTimeout(timer);
      reject(new Error("peer closed"));
    }
    this.pending.clear();
    this.onClose();
  }
}
