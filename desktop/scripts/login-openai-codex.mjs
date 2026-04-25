#!/usr/bin/env node
import { spawn } from "node:child_process";
import { stdin as input, stdout as output } from "node:process";
import { createInterface } from "node:readline/promises";
import { AuthStorage } from "../agent/node_modules/@mariozechner/pi-coding-agent/dist/core/auth-storage.js";
import { getAuthPath } from "../agent/node_modules/@mariozechner/pi-coding-agent/dist/config.js";

const provider = "openai-codex";
const readline = createInterface({ input, output });
const manualInputAbort = new AbortController();

process.once("SIGINT", () => {
  manualInputAbort.abort();
  readline.close();
  process.exit(130);
});

function openBrowser(url) {
  if (process.platform !== "darwin") return false;
  const child = spawn("open", [url], {
    detached: true,
    stdio: "ignore",
  });
  child.unref();
  return true;
}

try {
  const authStorage = AuthStorage.create();
  await authStorage.login(provider, {
    onAuth: ({ url, instructions }) => {
      console.log(instructions ?? "Complete OpenAI Codex OAuth in your browser.");
      console.log(url);
      if (openBrowser(url)) {
        console.log("Opened the login URL in your browser. Complete the flow there.");
      }
    },
    onPrompt: async (prompt) => {
      try {
        return await readline.question(`${prompt.message} `);
      } catch (error) {
        if (error?.code === "ERR_USE_AFTER_CLOSE") return "";
        throw error;
      }
    },
    onManualCodeInput: async () => {
      try {
        return await readline.question(
          "If the browser callback does not complete, paste the full redirect URL here: ",
          { signal: manualInputAbort.signal }
        );
      } catch (error) {
        if (error?.name === "AbortError") return "";
        throw error;
      }
    },
    onProgress: (message) => {
      console.log(message);
    },
  });

  console.log(`Saved ${provider} OAuth credentials to ${getAuthPath()}`);
} finally {
  manualInputAbort.abort();
  readline.close();
}
