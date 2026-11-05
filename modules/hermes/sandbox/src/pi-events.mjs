// Pi's JSON event stream (`pi --mode json`, docs/json.md in its package):
// strict LF-framed JSON lines on stdout. Only what Hermes needs is kept:
// progress counters for sandbox_status and Pi's last answer for the result.
// Everything here comes from the guest and is untrusted text.

const TEXT_LIMIT = 4000;

export class PiProgress {
  constructor() {
    this.buffer = "";
    this.sessionId = null;
    this.turns = 0;
    this.toolCalls = 0;
    this.lastTool = null;
    this.lastText = "";
    this.errors = [];
    this.settled = false;
    this.aborted = false;
    this.cost = 0;
    this.tokens = 0;
  }

  // Feeds stdout text; returns the events parsed from the complete lines.
  push(text) {
    this.buffer += text;
    const events = [];
    let newline;
    while ((newline = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, newline).replace(/\r$/, "");
      this.buffer = this.buffer.slice(newline + 1);
      if (!line.trim()) continue;
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        continue;
      }
      if (event && typeof event === "object") {
        this.#apply(event);
        events.push(event);
      }
    }
    return events;
  }

  #apply(event) {
    switch (event.type) {
      case "session":
        this.sessionId = typeof event.id === "string" ? event.id : null;
        break;
      case "turn_end":
        this.turns += 1;
        break;
      case "tool_execution_start":
        this.toolCalls += 1;
        this.lastTool = typeof event.toolName === "string" ? event.toolName.slice(0, 64) : null;
        break;
      case "message_end": {
        const message = event.message ?? {};
        if (message.role !== "assistant") break;
        const text = assistantText(message);
        if (text) this.lastText = text.slice(-TEXT_LIMIT);
        const usage = message.usage ?? {};
        if (Number.isFinite(usage.totalTokens)) this.tokens += usage.totalTokens;
        if (Number.isFinite(usage.cost?.total)) this.cost += usage.cost.total;
        if (message.stopReason === "error" && message.errorMessage) {
          this.errors.push(String(message.errorMessage).slice(0, 500));
        }
        break;
      }
      case "agent_settled":
        this.settled = true;
        this.aborted = event.aborted === true;
        break;
    }
  }

  snapshot() {
    return {
      turns: this.turns,
      tool_calls: this.toolCalls,
      last_tool: this.lastTool,
      tokens: this.tokens,
      cost: Math.round(this.cost * 10000) / 10000,
      errors: this.errors.slice(-3),
    };
  }
}

function assistantText(message) {
  if (typeof message.content === "string") return message.content.trim();
  if (!Array.isArray(message.content)) return "";
  return message.content
    .filter((block) => block?.type === "text" && typeof block.text === "string")
    .map((block) => block.text)
    .join("\n")
    .trim();
}
