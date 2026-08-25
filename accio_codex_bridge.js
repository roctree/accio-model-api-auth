const http = require("node:http");
const { spawn } = require("node:child_process");
const { EventEmitter } = require("node:events");

const HOST = "127.0.0.1";
const PORT = Number(process.env.ACCIO_CODEX_PORT || process.env.ACCIO_OPENCODE_PORT || 18765);
const MODEL = process.env.ACCIO_CODEX_MODEL || "gpt-5.6-sol";
const REASONING_EFFORT = process.env.ACCIO_CODEX_REASONING_EFFORT || "";
const CODEX_EXE = process.env.ACCIO_CODEX_EXE || "codex";
const CODEX_CWD = process.env.ACCIO_CODEX_CWD || process.cwd();
const MAX_BODY_BYTES = 32 * 1024 * 1024;
const BRIDGE_VERSION = "0.3.0";

function valueOf(object, camel, snake) {
  return object?.[camel] ?? object?.[snake];
}

function parseJson(value, fallback) {
  if (value === undefined || value === null || value === "") return fallback;
  if (typeof value !== "string") return value;
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

function textFromInstruction(instruction) {
  if (typeof instruction === "string") return instruction;
  return (Array.isArray(instruction?.parts) ? instruction.parts : [])
    .map((part) => (typeof part?.text === "string" ? part.text : ""))
    .join("");
}

function normalizeToolDeclaration(declaration) {
  const fn = declaration?.function ?? declaration?.functionDeclaration ?? declaration?.function_declaration ?? declaration;
  if (!fn?.name) return null;
  return {
    type: "function",
    name: fn.name,
    description: fn.description || "",
    inputSchema: parseJson(fn.parameters ?? fn.parametersJson ?? fn.parameters_json, { type: "object", properties: {} }),
  };
}

function dynamicToolsFromPayload(payload) {
  const normalized = [];
  for (const tool of Array.isArray(valueOf(payload, "tools", "tools")) ? valueOf(payload, "tools", "tools") : []) {
    const declarations = tool?.functionDeclarations ?? tool?.function_declarations;
    if (Array.isArray(declarations)) {
      for (const declaration of declarations) {
        const item = normalizeToolDeclaration(declaration);
        if (item) normalized.push(item);
      }
      continue;
    }
    const item = normalizeToolDeclaration(tool);
    if (item) normalized.push(item);
  }
  return normalized;
}

function functionCallFromPart(part) {
  const call = part?.functionCall ?? part?.function_call;
  if (!call) return null;
  const args = call.argsJson ?? call.args_json ?? call.arguments ?? call.args;
  return {
    id: call.id || "",
    name: call.name || "",
    arguments: typeof args === "string" ? args : JSON.stringify(args ?? {}),
  };
}

function functionResponseFromPart(part) {
  const response = part?.functionResponse ?? part?.function_response;
  if (!response) return null;
  const output = response.responseJson ?? response.response_json ?? response.response;
  return {
    id: response.id || "",
    name: response.name || "",
    output: typeof output === "string" ? output : JSON.stringify(output ?? {}),
  };
}

function functionResponsesFromPayload(payload) {
  const responses = [];
  const contents = Array.isArray(payload?.contents) ? payload.contents : [];
  for (let contentIndex = contents.length - 1; contentIndex >= 0; contentIndex -= 1) {
    const parts = Array.isArray(contents[contentIndex]?.parts) ? contents[contentIndex].parts : [];
    for (let partIndex = parts.length - 1; partIndex >= 0; partIndex -= 1) {
      const part = parts[partIndex];
      const response = functionResponseFromPart(part);
      if (response) responses.push(response);
    }
  }
  return responses;
}

function imageInputFromPart(part) {
  const inlineData = part?.inlineData ?? part?.inline_data;
  if (inlineData?.data) {
    const mimeType = inlineData.mimeType ?? inlineData.mime_type ?? "application/octet-stream";
    return { type: "image", url: `data:${mimeType};base64,${inlineData.data}` };
  }
  const fileData = part?.fileData ?? part?.file_data;
  const url = fileData?.fileUri ?? fileData?.file_uri;
  return url ? { type: "image", url } : null;
}

function conversationInputs(payload) {
  const inputs = [];
  const transcript = [];
  for (const content of Array.isArray(payload?.contents) ? payload.contents : []) {
    const role = content?.role === "model" ? "assistant" : content?.role === "function" ? "tool" : content?.role || "user";
    const lines = [];
    for (const part of Array.isArray(content?.parts) ? content.parts : []) {
      if (typeof part?.text === "string") lines.push(part.text);
      const call = functionCallFromPart(part);
      if (call) lines.push(`[tool call id=${call.id} name=${call.name}] ${call.arguments}`);
      const result = functionResponseFromPart(part);
      if (result) lines.push(`[tool result id=${result.id} name=${result.name}] ${result.output}`);
      const image = imageInputFromPart(part);
      if (image) inputs.push(image);
    }
    if (lines.length > 0) transcript.push(`<${role}>\n${lines.join("\n")}\n</${role}>`);
  }
  const text = transcript.length > 0
    ? `Accio conversation transcript, oldest to newest:\n${transcript.join("\n")}`
    : "Continue the Accio conversation.";
  inputs.unshift({ type: "text", text });
  return inputs;
}

function toolChoiceInstruction(payload) {
  const choice = valueOf(payload, "toolChoice", "tool_choice");
  if (typeof choice === "string") {
    const normalized = choice.toLowerCase();
    if (normalized === "none") return "Do not call a dynamic tool for this turn.";
    if (normalized === "any" || normalized === "required") return "Call one of the supplied dynamic tools before answering.";
  }
  const fn = choice?.functionCall ?? choice?.function_call ?? choice?.function;
  return fn?.name ? `Call the dynamic tool named ${fn.name} before answering.` : "";
}

function sendFrame(response, frame) {
  if (!response.writableEnded) response.write(`data: ${JSON.stringify(frame)}\n\n`);
}

function endWithError(response, code, message) {
  if (response.writableEnded) return;
  sendFrame(response, {
    content: { role: "model", parts: [{ text: "" }] },
    turnComplete: true,
    partial: false,
    errorCode: String(code),
    errorMessage: String(message),
    customMetadata: { model: MODEL, reasoning_effort: REASONING_EFFORT || "default", provider: "codex_chatgpt" },
  });
  response.end();
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    let bytes = 0;
    const chunks = [];
    request.on("data", (chunk) => {
      bytes += chunk.length;
      if (bytes > MAX_BODY_BYTES) {
        reject(new Error("request body too large"));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks)));
    request.on("error", reject);
  });
}

async function readJson(request) {
  return JSON.parse((await readBody(request)).toString("utf8"));
}

class CodexAppServer extends EventEmitter {
  constructor() {
    super();
    this.child = null;
    this.nextId = 1;
    this.pending = new Map();
    this.stdoutBuffer = "";
    this.stderrTail = "";
    this.account = null;
    this.requiresOpenaiAuth = true;
    this.models = [];
    this.ready = false;
    this.startError = null;
  }

  async start() {
    this.child = spawn(CODEX_EXE, ["app-server"], {
      cwd: CODEX_CWD,
      windowsHide: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child.stdout.on("data", (chunk) => this.onStdout(chunk));
    this.child.stderr.on("data", (chunk) => {
      this.stderrTail = (this.stderrTail + chunk.toString("utf8")).slice(-4000);
    });
    this.child.on("error", (error) => this.onExit(error));
    this.child.on("exit", (code, signal) => this.onExit(new Error(`Codex App Server exited (${code ?? signal})`)));

    await this.request("initialize", {
      clientInfo: { name: "accio-model-api-auth", title: "Accio Model API Auth", version: BRIDGE_VERSION },
      capabilities: { experimentalApi: true },
    });
    this.notify("initialized", {});
    await this.refreshStatus();
    this.ready = true;
  }

  onStdout(chunk) {
    this.stdoutBuffer += chunk.toString("utf8");
    const lines = this.stdoutBuffer.split(/\r?\n/);
    this.stdoutBuffer = lines.pop() || "";
    for (const line of lines) {
      if (!line.trim()) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        continue;
      }
      if (Object.prototype.hasOwnProperty.call(message, "id") && !message.method) {
        const pending = this.pending.get(String(message.id));
        if (!pending) continue;
        this.pending.delete(String(message.id));
        clearTimeout(pending.timer);
        if (message.error) pending.reject(new Error(message.error.message || JSON.stringify(message.error)));
        else pending.resolve(message.result);
        continue;
      }
      if (message.method && Object.prototype.hasOwnProperty.call(message, "id")) {
        this.emit("serverRequest", message);
        continue;
      }
      if (message.method) this.emit("notification", message);
    }
  }

  onExit(error) {
    if (this.startError) return;
    this.startError = error;
    this.ready = false;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
    this.emit("exit", error);
  }

  send(message) {
    if (!this.child?.stdin?.writable) throw this.startError || new Error("Codex App Server is not writable");
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  request(method, params, timeoutMs = 30000) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(String(id));
        reject(new Error(`${method} timed out`));
      }, timeoutMs);
      this.pending.set(String(id), { resolve, reject, timer });
      this.send({ id, method, params });
    });
  }

  notify(method, params) {
    this.send({ method, params });
  }

  respond(id, result) {
    this.send({ id, result });
  }

  respondError(id, code, message) {
    this.send({ id, error: { code, message } });
  }

  async refreshStatus() {
    const account = await this.request("account/read", { refreshToken: false });
    const models = await this.request("model/list", { limit: 100, includeHidden: false });
    this.account = account?.account || null;
    this.requiresOpenaiAuth = Boolean(account?.requiresOpenaiAuth);
    this.models = Array.isArray(models?.data) ? models.data : [];
    return this.publicStatus();
  }

  publicStatus() {
    return {
      ready: this.ready,
      authenticated: this.account?.type === "chatgpt",
      accountType: this.account?.type || null,
      planType: this.account?.type === "chatgpt" ? this.account.planType : null,
      requiresOpenaiAuth: this.requiresOpenaiAuth,
      model: MODEL,
      reasoningEffort: REASONING_EFFORT || "default",
      models: this.models.map((item) => ({
        id: item.id || item.model || item.slug || "",
        displayName: item.displayName || item.name || item.id || item.model || item.slug || "",
        isDefault: Boolean(item.isDefault || item.default),
        defaultReasoningEffort: item.defaultReasoningEffort || "",
        supportedReasoningEfforts: (Array.isArray(item.supportedReasoningEfforts) ? item.supportedReasoningEfforts : [])
          .map((effort) => typeof effort === "string" ? effort : effort?.reasoningEffort || effort?.effort || "")
          .filter(Boolean),
      })).filter((item) => item.id),
    };
  }

  async loginStart() {
    return this.request("account/login/start", { type: "chatgpt", appBrand: "codex" });
  }

  stop() {
    if (this.child && !this.child.killed) this.child.kill();
  }
}

class TurnContext {
  constructor(bridge, response) {
    this.bridge = bridge;
    this.response = null;
    this.threadId = "";
    this.turnId = "";
    this.pendingCalls = new Map();
    this.toolFlushTimer = null;
    this.finished = false;
    this.attachedPromise = this.attach(response);
  }

  attach(response) {
    if (this.response && !this.response.writableEnded) throw new Error("Codex turn already has an attached Accio response");
    this.response = response;
    return new Promise((resolve) => {
      this.resolveAttached = resolve;
      response.once("close", () => {
        if (this.response === response) {
          this.response = null;
          this.resolveAttached?.();
        }
      });
    });
  }

  detach() {
    const response = this.response;
    this.response = null;
    this.resolveAttached?.();
    this.resolveAttached = null;
    return response;
  }

  delta(text) {
    if (!text || !this.response || this.response.writableEnded) return;
    sendFrame(this.response, {
      content: { role: "model", parts: [{ text }] },
      partial: true,
      turnComplete: false,
      customMetadata: { model: MODEL, reasoning_effort: REASONING_EFFORT || "default", provider: "codex_chatgpt", thread_id: this.threadId, turn_id: this.turnId },
    });
  }

  addToolCall(rpcId, params) {
    const callId = params.callId || `call_${Math.random().toString(36).slice(2)}`;
    const call = {
      rpcId,
      callId,
      name: params.tool || "",
      namespace: params.namespace || null,
      arguments: typeof params.arguments === "string" ? params.arguments : JSON.stringify(params.arguments ?? {}),
      exposed: false,
    };
    this.pendingCalls.set(callId, call);
    pendingToolCalls.set(callId, { context: this, call });
    clearTimeout(this.toolFlushTimer);
    this.toolFlushTimer = setTimeout(() => this.flushToolCalls(), 75);
  }

  flushToolCalls() {
    const response = this.response;
    if (!response || response.writableEnded) return;
    const calls = [...this.pendingCalls.values()].filter((call) => !call.exposed);
    if (calls.length === 0) return;
    for (const call of calls) call.exposed = true;
    sendFrame(response, {
      content: {
        role: "model",
        parts: calls.map((call) => ({
          functionCall: { id: call.callId, name: call.name, argsJson: call.arguments || "{}" },
        })),
      },
      partial: false,
      turnComplete: true,
      finishReason: "TOOL_CALLS",
      customMetadata: { model: MODEL, reasoning_effort: REASONING_EFFORT || "default", provider: "codex_chatgpt", thread_id: this.threadId, turn_id: this.turnId },
    });
    response.end();
    this.detach();
  }

  complete(turn) {
    this.finished = true;
    clearTimeout(this.toolFlushTimer);
    for (const call of this.pendingCalls.values()) pendingToolCalls.delete(call.callId);
    this.pendingCalls.clear();
    const response = this.response;
    if (response && !response.writableEnded) {
      if (turn?.status === "failed") {
        endWithError(response, "CODEX_TURN_FAILED", turn?.error?.message || "Codex turn failed");
      } else {
        sendFrame(response, {
          content: { role: "model", parts: [] },
          partial: false,
          turnComplete: true,
          finishReason: "STOP",
          customMetadata: { model: MODEL, reasoning_effort: REASONING_EFFORT || "default", provider: "codex_chatgpt", thread_id: this.threadId, turn_id: this.turnId },
        });
        response.end();
      }
      this.detach();
    }
    turnContexts.delete(this.threadId);
  }

  fail(code, message) {
    this.finished = true;
    clearTimeout(this.toolFlushTimer);
    for (const call of this.pendingCalls.values()) pendingToolCalls.delete(call.callId);
    this.pendingCalls.clear();
    if (this.response) endWithError(this.response, code, message);
    this.detach();
    turnContexts.delete(this.threadId);
  }
}

const codex = new CodexAppServer();
const turnContexts = new Map();
const pendingToolCalls = new Map();

codex.on("serverRequest", (message) => {
  if (message.method !== "item/tool/call") {
    codex.respondError(message.id, -32601, `Unsupported Codex server request: ${message.method}`);
    const context = turnContexts.get(message.params?.threadId);
    context?.fail("CODEX_UNSUPPORTED_TOOL", `Codex requested unsupported built-in capability: ${message.method}`);
    return;
  }
  const context = turnContexts.get(message.params?.threadId);
  if (!context) {
    codex.respond(message.id, { success: false, contentItems: [{ type: "inputText", text: "Accio turn is no longer available" }] });
    return;
  }
  context.addToolCall(message.id, message.params || {});
});

codex.on("notification", (message) => {
  const params = message.params || {};
  const context = turnContexts.get(params.threadId);
  if (message.method === "item/agentMessage/delta") {
    context?.delta(params.delta);
    return;
  }
  if (message.method === "turn/completed") {
    context?.complete(params.turn);
    return;
  }
  if (message.method === "error" && !params.willRetry) {
    context?.fail("CODEX_ERROR", params.error?.message || "Codex App Server error");
    return;
  }
  if (message.method === "account/updated" || message.method === "account/login/completed") {
    codex.refreshStatus().catch(() => {});
  }
});

codex.on("exit", (error) => {
  for (const context of turnContexts.values()) context.fail("CODEX_APP_SERVER_EXIT", error.message);
});

function matchPendingResponses(payload) {
  const matches = [];
  for (const response of functionResponsesFromPayload(payload)) {
    let pending = response.id ? pendingToolCalls.get(response.id) : null;
    if (!pending && response.name) {
      pending = [...pendingToolCalls.values()].find((item) => item.call.name === response.name);
    }
    if (pending && !matches.some((item) => item.pending.call.callId === pending.call.callId)) {
      matches.push({ pending, response });
    }
  }
  return matches;
}

async function continueToolTurn(response, matches) {
  const contexts = new Set(matches.map((item) => item.pending.context));
  if (contexts.size !== 1) throw new Error("Tool responses belong to different Codex turns");
  const context = [...contexts][0];
  const attached = context.attach(response);
  for (const { pending, response: toolResponse } of matches) {
    const output = toolResponse.output || "{}";
    codex.respond(pending.call.rpcId, {
      success: true,
      contentItems: [{ type: "inputText", text: output }],
    });
    context.pendingCalls.delete(pending.call.callId);
    pendingToolCalls.delete(pending.call.callId);
  }
  await attached;
}

async function startTurn(response, payload) {
  const context = new TurnContext(codex, response);
  try {
    const systemInstruction = textFromInstruction(valueOf(payload, "systemInstruction", "system_instruction"));
    const choiceInstruction = toolChoiceInstruction(payload);
    const developerInstructions = [systemInstruction, choiceInstruction].filter(Boolean).join("\n\n") || null;
    const threadResult = await codex.request("thread/start", {
      model: MODEL,
      cwd: CODEX_CWD,
      approvalPolicy: "never",
      sandbox: "read-only",
      ephemeral: true,
      allowProviderModelFallback: false,
      baseInstructions: "You are the language model inside Accio. Follow the supplied Accio system instruction and conversation. Answer directly. You may call only dynamic tools supplied by Accio. Never call Codex built-in shell, file, web, MCP, skill, computer, or sub-agent tools. Do not mention this bridge or its protocol unless the user asks.",
      developerInstructions,
      dynamicTools: dynamicToolsFromPayload(payload),
    });
    context.threadId = threadResult?.thread?.id || "";
    if (!context.threadId) throw new Error("Codex thread/start returned no thread id");
    turnContexts.set(context.threadId, context);
    const turnResult = await codex.request("turn/start", {
      threadId: context.threadId,
      input: conversationInputs(payload),
      ...(REASONING_EFFORT ? { effort: REASONING_EFFORT } : {}),
    });
    context.turnId = turnResult?.turn?.id || "";
    await context.attachedPromise;
  } catch (error) {
    if (!context.finished) context.fail("CODEX_BRIDGE", error?.message || String(error));
    throw error;
  }
}

async function generate(response, payload) {
  if (!codex.ready) throw codex.startError || new Error("Codex App Server is not ready");
  if (codex.account?.type !== "chatgpt") throw new Error("Codex is not logged in with ChatGPT");
  const matches = matchPendingResponses(payload);
  if (matches.length > 0) await continueToolTurn(response, matches);
  else await startTurn(response, payload);
}

function jsonResponse(response, status, value) {
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(value));
}

const server = http.createServer(async (request, response) => {
  if (request.method === "GET" && request.url === "/healthz") {
    if (!codex.ready) {
      jsonResponse(response, 503, { ok: false, provider: "codex_chatgpt", model: MODEL, reasoningEffort: REASONING_EFFORT || "default", error: codex.startError?.message || "starting" });
      return;
    }
    const status = codex.publicStatus();
    jsonResponse(response, 200, {
      ok: true,
      provider: "codex_chatgpt",
      authType: "codex_chatgpt",
      endpoint: "codex-app-server://local",
      model: MODEL,
      reasoningEffort: REASONING_EFFORT || "default",
      authenticated: status.authenticated,
      accountType: status.accountType,
      planType: status.planType,
      availableModels: status.models.length,
    });
    return;
  }
  if (request.method === "GET" && request.url === "/codex/status") {
    try {
      jsonResponse(response, 200, await codex.refreshStatus());
    } catch (error) {
      jsonResponse(response, 503, { ready: false, error: error?.message || String(error) });
    }
    return;
  }
  if (request.method === "GET" && request.url === "/codex/models") {
    try {
      const status = await codex.refreshStatus();
      jsonResponse(response, 200, { model: MODEL, reasoningEffort: REASONING_EFFORT || "default", models: status.models });
    } catch (error) {
      jsonResponse(response, 503, { error: error?.message || String(error) });
    }
    return;
  }
  if (request.method === "POST" && request.url === "/codex/login/start") {
    try {
      jsonResponse(response, 200, await codex.loginStart());
    } catch (error) {
      jsonResponse(response, 503, { error: error?.message || String(error) });
    }
    return;
  }
  if (request.method === "POST" && request.url?.startsWith("/api/adk/llm/generateContent")) {
    response.writeHead(200, {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
    });
    try {
      await generate(response, await readJson(request));
    } catch (error) {
      endWithError(response, "CODEX_BRIDGE", error?.message || String(error));
    }
    return;
  }
  jsonResponse(response, 404, { error: "not found" });
});

server.listen(PORT, HOST, () => {
  console.log(`Accio Codex bridge listening on http://${HOST}:${PORT}`);
  console.log(`model=${MODEL}`);
  console.log(`reasoningEffort=${REASONING_EFFORT || "default"}`);
});

codex.start().catch((error) => {
  codex.startError = error;
  console.error(`Codex App Server startup failed: ${error.message}`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    codex.stop();
    server.close(() => process.exit(0));
  });
}
