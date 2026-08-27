const { spawn } = require("node:child_process");

const CODEX_EXE = process.env.ACCIO_CODEX_EXE || "codex";
const CODEX_CWD = process.env.ACCIO_CODEX_CWD || process.cwd();

class Client {
  constructor() {
    this.nextId = 1;
    this.pending = new Map();
    this.buffer = "";
  }

  async run() {
    this.child = spawn(CODEX_EXE, ["app-server"], {
      cwd: CODEX_CWD,
      windowsHide: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child.stdout.on("data", (chunk) => this.onData(chunk));
    this.child.on("error", (error) => this.fail(error));
    this.child.on("exit", (code, signal) => this.fail(new Error(`Codex App Server exited (${code ?? signal})`)));
    await this.request("initialize", {
      clientInfo: { name: "accio-model-api-auth-status", title: "Accio Codex Status", version: "0.4.0" },
      capabilities: { experimentalApi: true },
    });
    this.send({ method: "initialized", params: {} });
    const [account, models, providerCapabilities] = await Promise.all([
      this.request("account/read", { refreshToken: false }),
      this.request("model/list", { limit: 100, includeHidden: false }),
      this.request("modelProvider/capabilities/read", {}),
    ]);
    const authenticated = account?.account?.type === "chatgpt";
    let rateLimits = [];
    let rateLimitsError = null;
    let rateLimitResetCredits = null;
    let usageSummary = null;
    let dailyUsageBuckets = null;
    let usageError = null;

    if (authenticated) {
      const [rateLimitsResult, usageResult] = await Promise.allSettled([
        this.request("account/rateLimits/read"),
        this.request("account/usage/read"),
      ]);

      if (rateLimitsResult.status === "fulfilled") {
        const response = rateLimitsResult.value;
        const limitsById = response?.rateLimitsByLimitId;
        const limits = limitsById && typeof limitsById === "object"
          ? Object.values(limitsById)
          : response?.rateLimits
            ? [response.rateLimits]
            : [];
        rateLimits = limits.map((limit) => ({
          limitId: limit?.limitId || "",
          limitName: limit?.limitName || "",
          planType: limit?.planType || "",
          primary: normalizeRateLimitWindow(limit?.primary),
          secondary: normalizeRateLimitWindow(limit?.secondary),
          credits: limit?.credits || null,
          rateLimitReachedType: limit?.rateLimitReachedType || null,
        }));
        rateLimitResetCredits = response?.rateLimitResetCredits || null;
      } else {
        rateLimitsError = rateLimitsResult.reason?.message || String(rateLimitsResult.reason);
      }

      if (usageResult.status === "fulfilled") {
        usageSummary = usageResult.value?.summary || null;
        dailyUsageBuckets = Array.isArray(usageResult.value?.dailyUsageBuckets)
          ? usageResult.value.dailyUsageBuckets
          : null;
      } else {
        usageError = usageResult.reason?.message || String(usageResult.reason);
      }
    }

    return {
      authenticated,
      accountType: account?.account?.type || null,
      planType: authenticated ? account.account.planType : null,
      requiresOpenaiAuth: Boolean(account?.requiresOpenaiAuth),
      imageGenerationAvailable: Boolean(providerCapabilities?.imageGeneration),
      rateLimits,
      rateLimitsError,
      rateLimitResetCredits,
      usageSummary,
      dailyUsageBuckets,
      usageError,
      models: (Array.isArray(models?.data) ? models.data : []).map((item) => ({
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

  onData(chunk) {
    this.buffer += chunk.toString("utf8");
    const lines = this.buffer.split(/\r?\n/);
    this.buffer = lines.pop() || "";
    for (const line of lines) {
      if (!line.trim()) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        continue;
      }
      if (!Object.prototype.hasOwnProperty.call(message, "id") || message.method) continue;
      const pending = this.pending.get(String(message.id));
      if (!pending) continue;
      this.pending.delete(String(message.id));
      clearTimeout(pending.timer);
      if (message.error) pending.reject(new Error(message.error.message || JSON.stringify(message.error)));
      else pending.resolve(message.result);
    }
  }

  send(message) {
    if (!this.child?.stdin?.writable) throw new Error("Codex App Server is not writable");
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  request(method, params) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(String(id));
        reject(new Error(`${method} timed out`));
      }, 30000);
      this.pending.set(String(id), { resolve, reject, timer });
      const message = { id, method };
      if (params !== undefined) message.params = params;
      this.send(message);
    });
  }

  fail(error) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }

  stop() {
    if (this.child && !this.child.killed) this.child.kill();
  }
}

function normalizeRateLimitWindow(window) {
  if (!window) return null;
  return {
    usedPercent: window.usedPercent ?? null,
    windowDurationMins: window.windowDurationMins ?? null,
    resetsAt: window.resetsAt ?? null,
  };
}

(async () => {
  const client = new Client();
  try {
    const status = await client.run();
    process.stdout.write(`${JSON.stringify(status)}\n`);
  } catch (error) {
    process.stderr.write(`${error?.message || String(error)}\n`);
    process.exitCode = 1;
  } finally {
    client.stop();
  }
})();
