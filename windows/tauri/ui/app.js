const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const textInput = document.querySelector("#textInput");
const textInfo = document.querySelector("#textInfo");
const delayMs = document.querySelector("#delayMs");
const countdownSeconds = document.querySelector("#countdownSeconds");
const uiScale = document.querySelector("#uiScale");
const allowReturn = document.querySelector("#allowReturn");
const dryRun = document.querySelector("#dryRun");
const monitorCopy = document.querySelector("#monitorCopy");
const startButton = document.querySelector("#startButton");
const stopButton = document.querySelector("#stopButton");
const statusLine = document.querySelector("#status");
const safetyNotice = document.querySelector("#safetyNotice");
const noticeClose = document.querySelector("#noticeClose");

let countdownToken = 0;
let busy = false;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const boundedNumber = (element, fallback, min, max) => {
  const parsed = Number.parseInt(element.value, 10);
  const value = Number.isFinite(parsed) ? Math.min(max, Math.max(min, parsed)) : fallback;
  element.value = String(value);
  return value;
};

function setStatus(message) { statusLine.textContent = message; }

function applyScaleAttribute(scale) {
  document.documentElement.dataset.uiScale = scale;
  document.body.dataset.uiScale = scale;
}

function updateTextInfo() {
  const text = textInput.value;
  const lines = text.length === 0 ? 1 : text.split(/\r\n|\r|\n/).length;
  textInfo.textContent = `${Array.from(text).length} 字符 · ${lines} 行`;
}

function updateStartText() {
  if (!busy) startButton.textContent = `${boundedNumber(countdownSeconds, 3, 1, 30)} 秒后输入`;
}

function setBusy(value) {
  busy = value;
  textInput.disabled = value;
  delayMs.disabled = value;
  countdownSeconds.disabled = value;
  uiScale.disabled = value;
  allowReturn.disabled = value;
  dryRun.disabled = value;
  monitorCopy.disabled = value;
  startButton.disabled = value;
}

async function stopTyping(message = "已请求停止") {
  countdownToken += 1;
  await invoke("stop_typing");
  setStatus(message);
}

async function beginTyping() {
  const text = textInput.value;
  if (!text) {
    setStatus("请先输入或复制需要发送的内容");
    textInput.focus();
    return;
  }

  const token = ++countdownToken;
  const seconds = boundedNumber(countdownSeconds, 3, 1, 30);
  const interval = boundedNumber(delayMs, 10, 0, 1000);
  setBusy(true);

  try {
    for (let remaining = seconds; remaining > 0; remaining -= 1) {
      if (token !== countdownToken) return;
      startButton.textContent = `${remaining} 秒后输入`;
      setStatus(`请点击要输入的位置（${remaining} 秒后输入）`);
      await sleep(1000);
    }
    if (token !== countdownToken) return;
    startButton.textContent = "正在输入…";
    setStatus("正在模拟键盘输入，按 Ctrl+Alt+Esc 可停止");

    const result = await invoke("send_text", {
      text,
      delayMs: interval,
      allowReturn: allowReturn.checked,
      dryRun: dryRun.checked
    });
    setStatus(result);
  } catch (error) {
    setStatus(`输入失败：${String(error)}`);
  } finally {
    if (token === countdownToken) {
      setBusy(false);
      updateStartText();
    }
  }
}

textInput.addEventListener("input", updateTextInfo);
countdownSeconds.addEventListener("input", updateStartText);
countdownSeconds.addEventListener("change", updateStartText);
delayMs.addEventListener("change", () => boundedNumber(delayMs, 10, 0, 1000));
startButton.addEventListener("click", beginTyping);
stopButton.addEventListener("click", () => stopTyping());
noticeClose.addEventListener("click", () => {
  safetyNotice.classList.add("is-dismissed");
  safetyNotice.hidden = true;
});
monitorCopy.addEventListener("change", async () => {
  try {
    await invoke("set_monitor_copy", { enabled: monitorCopy.checked });
    setStatus(monitorCopy.checked ? "已开启 Ctrl+C 监听" : "已关闭 Ctrl+C 监听");
  } catch (error) {
    monitorCopy.checked = !monitorCopy.checked;
    setStatus(`设置失败：${String(error)}`);
  }
});
uiScale.addEventListener("change", async () => {
  const previous = document.body.dataset.uiScale || "medium";
  applyScaleAttribute(uiScale.value);
  try {
    await invoke("set_ui_scale", { scale: uiScale.value });
    setStatus(`界面大小已切换为${uiScale.options[uiScale.selectedIndex].text}`);
  } catch (error) {
    uiScale.value = previous;
    applyScaleAttribute(previous);
    setStatus(`界面缩放失败：${String(error)}`);
  }
});

window.addEventListener("DOMContentLoaded", async () => {
  safetyNotice.hidden = false;
  safetyNotice.classList.remove("is-dismissed");
  noticeClose.hidden = true;
  window.setTimeout(() => { noticeClose.hidden = false; }, 5000);
  updateTextInfo();
  updateStartText();
  try {
    const state = await invoke("initial_state");
    monitorCopy.checked = state.monitorCopy;
    uiScale.value = state.uiScale;
    applyScaleAttribute(state.uiScale);
    setStatus(state.hotkeyReady ? "就绪" : "就绪；Ctrl+Alt+Esc 热键已被其他程序占用");
  } catch (error) {
    setStatus(`初始化提示：${String(error)}`);
  }

  await listen("clipboard-text", ({ payload }) => {
    if (busy || typeof payload !== "string") return;
    textInput.value = payload;
    updateTextInfo();
    setStatus("已读取剪贴板内容");
  });

  await listen("stop-requested", () => {
    countdownToken += 1;
    setStatus("输入已停止");
    if (busy) {
      setBusy(false);
      updateStartText();
    }
  });
});
