// request_host_action: Pi's one way to ask Hermes for something outside the
// VM (a host, a folder of the Mac, a push, the owner's answer, a command on
// the Mac). Each call is one TYPED action, POSTed to Hermes' broker
// ($HERMES_BROKER_URL) with this session's token ($HERMES_BROKER_TOKEN);
// Hermes' approval system decides, on the action alone. There is no field
// for reasons: none would be read.
//
// Plain JavaScript and Node's https (no imports from Pi): the broker may hold
// the request while the owner decides, longer than fetch()'s 300 s header
// timeout.

import https from "node:https";
import http from "node:http";

const str = (description, extra = {}) => ({ type: "string", description, ...extra });
const only = (action) => ({ type: "string", enum: [action] });

// Discriminated by `action`: one closed object per action. Under `request`,
// since providers want an object at the root of a tool's parameters.
const REQUEST = {
  anyOf: [
    {
      type: "object",
      description: "A network grant for this session, asked before the requests that need it.",
      properties: {
        action: only("request_host"),
        host: str("Host name, e.g. pypi.org, or *.example.com for its subdomains."),
        method: str("HTTP method the grant covers (GET, POST…); omit for any."),
        pathPrefix: str("Path prefix the grant covers, e.g. /simple; omit for any path."),
      },
      required: ["action", "host"],
      additionalProperties: false,
    },
    {
      type: "object",
      description: "A read-only copy of a folder of the host machine, under /host/<name> in this VM.",
      properties: { action: only("request_folder"), path: str("Absolute path on the host (or ~/…).") },
      required: ["action", "path"],
      additionalProperties: false,
    },
    {
      type: "object",
      description: "Push a branch of /workspace/repo to the repository's origin (a new branch or a fast-forward).",
      properties: {
        action: only("git_push"),
        branch: str("This session's branch (sandbox/<session>, or sandbox/<session>-<name>), committed first."),
      },
      required: ["action", "branch"],
      additionalProperties: false,
    },
    {
      type: "object",
      description: "A question for the user, answered by tapping one of the choices.",
      properties: {
        action: only("ask_user"),
        question: str("The question, self-contained."),
        choices: { type: "array", items: { type: "string" }, minItems: 2, maxItems: 4, description: "2 to 4 short answers." },
      },
      required: ["action", "question", "choices"],
      additionalProperties: false,
    },
    {
      type: "object",
      description: "A shell command on the host machine (not this VM), run only if the user approves it.",
      properties: {
        action: only("shell"),
        command: str("The command (bash)."),
        cwd: str("Absolute host folder to run it in; omit for a new empty one."),
      },
      required: ["action", "command"],
      additionalProperties: false,
    },
  ],
};

function post(url, token, body, signal) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const data = Buffer.from(JSON.stringify(body));
    const request = (target.protocol === "http:" ? http : https).request(target, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
        "content-length": data.length,
      },
      signal,
    }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => resolve({ status: response.statusCode, text: Buffer.concat(chunks).toString("utf8") }));
      response.on("error", reject);
    });
    request.on("error", reject);
    request.end(data);
  });
}

export default function (pi) {
  pi.registerTool({
    name: "request_host_action",
    label: "Ask Hermes",
    description: [
      "Ask Hermes, who runs this VM, for something outside it. Inside the VM you need no permission: run, edit and",
      "test freely. Use this only for: a network host you cannot reach yet (requests to unknown hosts are paused or",
      "refused with 403), a folder of the host machine (copied read-only to /host/<name>), pushing your branch, a",
      "question for the user, or a command that must run on the host. Each call is one typed action; the action is",
      "judged on its own, there is no place for explanations. Answers are minimal: {ok, status: allowed | denied |",
      "timeout | error, result?}, never a reason. A denial or a timeout is final for this session: do not ask again",
      "for the same thing, find another way or finish without it. A call may take minutes while the user decides.",
    ].join(" "),
    promptSnippet: "Ask Hermes for a host, a host folder, a push, the user's answer, or a host command",
    promptGuidelines: [
      "Use request_host_action only for what the VM cannot do itself; a denied request_host_action is final for the session.",
    ],
    parameters: {
      type: "object",
      properties: { request: REQUEST },
      required: ["request"],
      additionalProperties: false,
    },
    executionMode: "sequential",
    async execute(_toolCallId, params, signal) {
      const url = process.env.HERMES_BROKER_URL;
      const token = process.env.HERMES_BROKER_TOKEN;
      if (!url || !token) throw new Error("Hermes' broker is not configured in this VM");
      const { status, text } = await post(url, token, params.request, signal);
      let answer;
      try {
        answer = JSON.parse(text);
      } catch {
        answer = { ok: false, status: "error", result: { error: `HTTP ${status}` } };
      }
      return {
        content: [{ type: "text", text: JSON.stringify(answer) }],
        details: answer,
        ...(answer.ok ? {} : { isError: true }),
      };
    },
  });
}
