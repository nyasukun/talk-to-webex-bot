import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { chmod, mkdir, readFile, unlink, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { promisify } from "node:util";

export const appDirectory = join(homedir(), "Library", "Application Support", "LocalVoiceRelay");
export interface UseCase {
  id: string;
  name: string;
  readReplies: boolean;
  hotkey?: string;
  confirmBeforeSending: boolean;
}
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function applicationPath(text: string): string {
  const path: unknown = JSON.parse(text).applicationPath;
  if (typeof path !== "string" || !path.startsWith("/") || !path.endsWith(".app")) {
    throw new Error("アプリの場所を読み込めません。更新版のTalk to Webex botを一度起動してください。");
  }
  return path;
}

export async function openApplication() {
  const text = await readFile(join(appDirectory, "screen-use-cases.json"), "utf8");
  await promisify(execFile)("/usr/bin/open", ["-a", applicationPath(text)]);
}

export function parseCatalog(text: string): UseCase[] {
  const value: unknown = JSON.parse(text);
  if (!value || typeof value !== "object" || !("version" in value) || value.version !== 1 ||
      !("useCases" in value) || !Array.isArray(value.useCases)) throw new Error("一覧の形式が古いか不正です。アプリを更新して設定を保存してください。");
  const ids = new Set<string>();
  return value.useCases.map((entry: unknown) => {
    if (!entry || typeof entry !== "object") throw new Error("ユースケースを読み取れません。");
    const item = entry as Record<string, unknown>;
    if (typeof item.id !== "string" || !uuid.test(item.id) || ids.has(item.id.toUpperCase()) ||
        typeof item.name !== "string" || !item.name.trim() || typeof item.readReplies !== "boolean" ||
        typeof item.confirmBeforeSending !== "boolean" || (item.hotkey != null && typeof item.hotkey !== "string")) {
      throw new Error("ユースケースを読み取れません。アプリで設定を保存し直してください。");
    }
    ids.add(item.id.toUpperCase());
    return { id: item.id, name: item.name, readReplies: item.readReplies,
      confirmBeforeSending: item.confirmBeforeSending, hotkey: item.hotkey ?? undefined } as UseCase;
  });
}

export async function loadCatalog(directory = appDirectory): Promise<UseCase[]> {
  try { return parseCatalog(await readFile(join(directory, "screen-use-cases.json"), "utf8")); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      throw new Error("Talk to Webex botを一度起動してください。「画面ホットキー」の保存済み設定が表示されます。");
    }
    throw error;
  }
}

export async function submitRequest(
  useCase: UseCase,
  expectedBundleID: string,
  directory = appDirectory,
  dispatch: (url: string, appPath: string) => Promise<unknown> = (url, appPath) => promisify(execFile)("/usr/bin/open", ["-g", "-a", appPath, url]),
): Promise<string> {
  if (!uuid.test(useCase.id) || !expectedBundleID || ["com.raycast.macos", "org.localvoicerelay.app", "com.apple.loginwindow"].includes(expectedBundleID)) {
    throw new Error("対象のアプリを前面にしてからRaycastを開き直してください。");
  }
  // Re-read on selection: a deleted or disabled item from an old list must not execute.
  const saved = await readFile(join(directory, "screen-use-cases.json"), "utf8");
  if (!parseCatalog(saved).some((entry) => entry.id === useCase.id)) {
    throw new Error("このユースケースは削除または無効化されています。一覧を更新してください。");
  }
  const appPath = applicationPath(saved);
  const requests = join(directory, "raycast-requests");
  await mkdir(requests, { recursive: true, mode: 0o700 });
  await chmod(requests, 0o700);
  const id = randomUUID().toUpperCase();
  const requestPath = join(requests, `${id}.json`);
  const responsePath = join(requests, `${id}.response.json`);
  await writeFile(requestPath, JSON.stringify({ useCaseID: useCase.id, createdAt: Date.now() / 1000, expectedBundleID }), { flag: "wx", mode: 0o600 });
  try {
    await dispatch(`talk-to-webex-bot://run?request=${id}`, appPath);
    for (let attempt = 0; attempt < 100; attempt++) {
      try {
        const response: unknown = JSON.parse(await readFile(responsePath, "utf8"));
        if (!response || typeof response !== "object" || !("accepted" in response) || typeof response.accepted !== "boolean" ||
            !("message" in response) || typeof response.message !== "string") throw new Error("アプリからの応答が不正です。");
        if (!response.accepted) throw new Error(response.message);
        return response.message;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
      await delay(100);
    }
    throw new Error("アプリの応答を確認できません。Talk to Webex botで状態を確認してください。自動再実行はしません。");
  } finally {
    await Promise.all([unlink(requestPath).catch(() => {}), unlink(responsePath).catch(() => {})]);
  }
}
