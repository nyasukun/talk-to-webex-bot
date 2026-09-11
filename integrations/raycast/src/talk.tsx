import { Action, ActionPanel, closeMainWindow, getFrontmostApplication, Icon, List, showHUD } from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import { setTimeout as delay } from "node:timers/promises";
import { loadCatalog, openApplication, submitRequest, UseCase } from "./catalog";

export default function Talk() {
  const [useCases, setUseCases] = useState<UseCase[]>([]);
  const [isLoading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const running = useRef(false);

  async function refresh() {
    setLoading(true);
    setError("");
    try { setUseCases(await loadCatalog()); }
    catch (error) { setUseCases([]); setError(error instanceof Error ? error.message : "一覧を読み込めません。"); }
    finally { setLoading(false); }
  }
  useEffect(() => { void refresh(); }, []);

  async function run(useCase: UseCase) {
    if (running.current) return;
    running.current = true;
    try {
      await closeMainWindow({ clearRootSearch: true });
      // Allow Raycast's closing animation to restore the previously active application.
      await delay(200);
      const target = await getFrontmostApplication();
      const message = await submitRequest(useCase, target.bundleId ?? "");
      await showHUD(`${useCase.name}: ${message}`);
    } catch (error) {
      await showHUD(error instanceof Error ? error.message : "実行できませんでした。");
    } finally { running.current = false; }
  }

  function secondaryActions() {
    return <>
      <Action title="一覧を更新" icon={Icon.ArrowClockwise} shortcut={{ modifiers: ["cmd"], key: "r" }} onAction={refresh} />
      <Action title="アプリの設定を開く" icon={Icon.Gear} onAction={openApplication} />
    </>;
  }

  return <List isLoading={isLoading} searchBarPlaceholder="ユースケースを検索…" navigationTitle="Talk to Webex bot">
    <List.EmptyView title={error ? "一覧を読み込めません" : "有効なユースケースがありません"}
      description={error || "アプリの「画面ホットキー」でユースケースを追加・有効化し、保存してください。"}
      actions={<ActionPanel>{secondaryActions()}</ActionPanel>} />
    {useCases.map((useCase) => <List.Item key={useCase.id} id={useCase.id} title={useCase.name}
      icon={Icon.Window} keywords={["talk", "webex", useCase.hotkey ?? ""]}
      accessories={[
        { text: useCase.confirmBeforeSending ? "送信前確認" : "直接送信" },
        { icon: useCase.readReplies ? Icon.SpeakerOn : Icon.SpeakerOff, tooltip: useCase.readReplies ? "返信読み上げ ON" : "返信読み上げ OFF" },
        ...(useCase.hotkey ? [{ text: useCase.hotkey }] : []),
      ]}
      actions={<ActionPanel>
        <Action title="この画面で実行" icon={Icon.Play} onAction={() => run(useCase)} />
        {secondaryActions()}
      </ActionPanel>} />)}
  </List>;
}
