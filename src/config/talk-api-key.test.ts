import { describe, expect, it } from "vitest";
import { resolveTalkApiKey } from "./talk.js";

describe("talk api key resolution", () => {
  it("reads ELEVENLABS_API_KEY from environment", () => {
    const value = resolveTalkApiKey(null, { ELEVENLABS_API_KEY: "env-key" });
    expect(value).toBe("env-key");
  });

  it("reads MISTRAL_API_KEY from environment when provider is mistral", () => {
    const value = resolveTalkApiKey("mistral", { MISTRAL_API_KEY: "mistral-key" });
    expect(value).toBe("mistral-key");
  });

  it("falls back to ELEVENLABS_API_KEY when provider is mistral but MISTRAL_API_KEY is missing", () => {
    const value = resolveTalkApiKey("mistral", { ELEVENLABS_API_KEY: "fallback-key" });
    expect(value).toBe("fallback-key");
  });

  it("respects provider-specific env var over legacy fallback even if legacy is present", () => {
    const value = resolveTalkApiKey("mistral", {
      MISTRAL_API_KEY: "mistral-key",
      ELEVENLABS_API_KEY: "legacy-key",
    });
    expect(value).toBe("mistral-key");
  });
});
