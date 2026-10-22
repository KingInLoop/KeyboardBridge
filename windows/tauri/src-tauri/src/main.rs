#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::Serialize;
use std::{
    mem::size_of,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc, OnceLock,
    },
    thread,
    time::Duration,
};
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, LogicalSize, Manager, WindowEvent,
};
use windows_sys::Win32::{
    Foundation::{LPARAM, LRESULT, WPARAM},
    System::LibraryLoader::GetModuleHandleW,
    UI::{
        Input::KeyboardAndMouse::{
            GetAsyncKeyState, MapVirtualKeyW, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD,
            KEYBDINPUT, KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE, KEYEVENTF_UNICODE,
            MAPVK_VK_TO_VSC, MOD_ALT, MOD_CONTROL, RegisterHotKey, UnregisterHotKey,
            VK_CONTROL, VK_ESCAPE, VK_LSHIFT, VK_RETURN,
        },
        WindowsAndMessaging::{
            CallNextHookEx, DispatchMessageW, GetMessageW, SetWindowsHookExW, TranslateMessage,
            UnhookWindowsHookEx, HHOOK, KBDLLHOOKSTRUCT, MSG, WH_KEYBOARD_LL, WM_HOTKEY,
            WM_KEYDOWN, WM_SYSKEYDOWN,
        },
    },
};
use winreg::{enums::HKEY_CURRENT_USER, RegKey};

const HOTKEY_ID: i32 = 0x4B42;
const REGISTRY_PATH: &str = r"Software\KeyboardBridge";
const REGISTRY_MONITOR: &str = "MonitorCopyShortcut";
const REGISTRY_UI_SCALE: &str = "UiScale";
const VK_C: u32 = 0x43;

static APP: OnceLock<AppHandle> = OnceLock::new();
static MONITOR_COPY: AtomicBool = AtomicBool::new(true);
static HOTKEY_READY: AtomicBool = AtomicBool::new(false);
static STOP_REQUESTED: AtomicBool = AtomicBool::new(false);
static LAST_COPY_TICK: AtomicU64 = AtomicU64::new(0);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct InitialState {
    monitor_copy: bool,
    hotkey_ready: bool,
    ui_scale: String,
}

#[tauri::command]
fn initial_state() -> InitialState {
    InitialState {
        monitor_copy: MONITOR_COPY.load(Ordering::Relaxed),
        hotkey_ready: HOTKEY_READY.load(Ordering::Relaxed),
        ui_scale: load_ui_scale(),
    }
}

#[tauri::command(rename_all = "camelCase")]
fn set_monitor_copy(enabled: bool) -> Result<(), String> {
    MONITOR_COPY.store(enabled, Ordering::Relaxed);
    save_monitor_copy(enabled)
}

#[tauri::command]
fn set_ui_scale(app: AppHandle, scale: String) -> Result<(), String> {
    apply_window_scale(&app, &scale)?;
    save_ui_scale(&scale)
}

#[tauri::command]
fn stop_typing() {
    STOP_REQUESTED.store(true, Ordering::Relaxed);
}

#[tauri::command(rename_all = "camelCase")]
async fn send_text(
    text: String,
    delay_ms: u64,
    allow_return: bool,
    dry_run: bool,
) -> Result<String, String> {
    STOP_REQUESTED.store(false, Ordering::Relaxed);
    let delay_ms = delay_ms.min(1000);
    tauri::async_runtime::spawn_blocking(move || {
        let plan = build_plan(&text, allow_return);
        if dry_run {
            return Ok(format!(
                "演练完成：共 {} 个输入单元，未发送按键{}",
                plan.units.len(),
                replacement_note(plan.replaced_newlines)
            ));
        }

        let mut sent = 0usize;
        for unit in plan.units {
            if STOP_REQUESTED.load(Ordering::Relaxed) {
                return Ok(format!("输入已停止：已发送 {sent} 个输入单元"));
            }
            emit_unit(unit)?;
            sent += 1;
            if delay_ms > 0 {
                thread::sleep(Duration::from_millis(delay_ms));
            }
        }
        Ok(format!(
            "输入完成：共发送 {sent} 个输入单元{}",
            replacement_note(plan.replaced_newlines)
        ))
    })
    .await
    .map_err(|error| error.to_string())?
}

fn replacement_note(count: usize) -> String {
    if count == 0 {
        String::new()
    } else {
        format!("；已将 {count} 个换行替换为空格")
    }
}

struct InputPlan {
    units: Vec<char>,
    replaced_newlines: usize,
}

fn build_plan(text: &str, allow_return: bool) -> InputPlan {
    let mut units = Vec::with_capacity(text.chars().count());
    let mut replaced = 0usize;
    let mut chars = text.chars().peekable();
    while let Some(character) = chars.next() {
        if character == '\r' {
            if chars.peek() == Some(&'\n') {
                chars.next();
            }
            units.push(if allow_return { '\n' } else { ' ' });
            if !allow_return { replaced += 1; }
        } else if character == '\n' {
            units.push(if allow_return { '\n' } else { ' ' });
            if !allow_return { replaced += 1; }
        } else {
            units.push(character);
        }
    }
    InputPlan { units, replaced_newlines: replaced }
}

#[derive(Clone, Copy)]
struct PhysicalKey {
    virtual_key: u16,
    shift: bool,
}

fn map_physical(character: char) -> Option<PhysicalKey> {
    if character.is_ascii_lowercase() {
        return Some(PhysicalKey { virtual_key: character.to_ascii_uppercase() as u16, shift: false });
    }
    if character.is_ascii_uppercase() {
        return Some(PhysicalKey { virtual_key: character as u16, shift: true });
    }
    if character.is_ascii_digit() {
        return Some(PhysicalKey { virtual_key: character as u16, shift: false });
    }
    const PLAIN: &[(char, u16)] = &[
        (' ', 0x20), (';', 0xBA), ('=', 0xBB), (',', 0xBC), ('-', 0xBD),
        ('.', 0xBE), ('/', 0xBF), ('`', 0xC0), ('[', 0xDB), ('\\', 0xDC),
        (']', 0xDD), ('\'', 0xDE),
    ];
    const SHIFTED: &[(char, u16)] = &[
        (')', 0x30), ('!', 0x31), ('@', 0x32), ('#', 0x33), ('$', 0x34),
        ('%', 0x35), ('^', 0x36), ('&', 0x37), ('*', 0x38), ('(', 0x39),
        (':', 0xBA), ('+', 0xBB), ('<', 0xBC), ('_', 0xBD), ('>', 0xBE),
        ('?', 0xBF), ('~', 0xC0), ('{', 0xDB), ('|', 0xDC), ('}', 0xDD),
        ('"', 0xDE),
    ];
    PLAIN.iter().find(|(ch, _)| *ch == character).map(|(_, vk)| PhysicalKey { virtual_key: *vk, shift: false })
        .or_else(|| SHIFTED.iter().find(|(ch, _)| *ch == character).map(|(_, vk)| PhysicalKey { virtual_key: *vk, shift: true }))
}

fn emit_unit(character: char) -> Result<(), String> {
    if character == '\n' {
        return send_physical(PhysicalKey { virtual_key: VK_RETURN as u16, shift: false });
    }
    if let Some(key) = map_physical(character) {
        send_physical(key)
    } else {
        let mut buffer = [0u16; 2];
        for unit in character.encode_utf16(&mut buffer).iter().copied() {
            send_unicode(unit)?;
        }
        Ok(())
    }
}

fn send_physical(key: PhysicalKey) -> Result<(), String> {
    let scan = unsafe { MapVirtualKeyW(key.virtual_key as u32, MAPVK_VK_TO_VSC) } as u16;
    if scan == 0 { return Err("无法映射物理按键".into()); }
    let shift_scan = unsafe { MapVirtualKeyW(VK_LSHIFT as u32, MAPVK_VK_TO_VSC) } as u16;
    let mut inputs = Vec::with_capacity(if key.shift { 4 } else { 2 });
    if key.shift { inputs.push(keyboard_input(shift_scan, KEYEVENTF_SCANCODE)); }
    inputs.push(keyboard_input(scan, KEYEVENTF_SCANCODE));
    inputs.push(keyboard_input(scan, KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP));
    if key.shift { inputs.push(keyboard_input(shift_scan, KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP)); }
    send_inputs(&inputs)
}

fn send_unicode(unit: u16) -> Result<(), String> {
    send_inputs(&[
        keyboard_input(unit, KEYEVENTF_UNICODE),
        keyboard_input(unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP),
    ])
}

fn keyboard_input(scan: u16, flags: u32) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT { wVk: 0, wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 },
        },
    }
}

fn send_inputs(inputs: &[INPUT]) -> Result<(), String> {
    let count = unsafe { SendInput(inputs.len() as u32, inputs.as_ptr(), size_of::<INPUT>() as i32) };
    if count == inputs.len() as u32 {
        Ok(())
    } else {
        Err(format!("SendInput 失败（Win32={}，INPUT={} 字节）", std::io::Error::last_os_error().raw_os_error().unwrap_or(0), size_of::<INPUT>()))
    }
}

fn load_monitor_copy() -> bool {
    RegKey::predef(HKEY_CURRENT_USER)
        .open_subkey(REGISTRY_PATH)
        .and_then(|key| key.get_value::<u32, _>(REGISTRY_MONITOR))
        .map(|value| value != 0)
        .unwrap_or(true)
}

fn save_monitor_copy(enabled: bool) -> Result<(), String> {
    let (key, _) = RegKey::predef(HKEY_CURRENT_USER)
        .create_subkey(REGISTRY_PATH)
        .map_err(|error| error.to_string())?;
    key.set_value(REGISTRY_MONITOR, &(enabled as u32)).map_err(|error| error.to_string())
}

fn load_ui_scale() -> String {
    RegKey::predef(HKEY_CURRENT_USER)
        .open_subkey(REGISTRY_PATH)
        .and_then(|key| key.get_value::<String, _>(REGISTRY_UI_SCALE))
        .ok()
        .filter(|value| matches!(value.as_str(), "small" | "medium" | "large"))
        .unwrap_or_else(|| "medium".to_string())
}

fn save_ui_scale(scale: &str) -> Result<(), String> {
    if !matches!(scale, "small" | "medium" | "large") {
        return Err("不支持的界面大小".into());
    }
    let (key, _) = RegKey::predef(HKEY_CURRENT_USER)
        .create_subkey(REGISTRY_PATH)
        .map_err(|error| error.to_string())?;
    key.set_value(REGISTRY_UI_SCALE, &scale).map_err(|error| error.to_string())
}

fn window_dimensions(scale: &str) -> Result<(f64, f64, f64, f64), String> {
    match scale {
        "small" => Ok((576.0, 472.0, 336.0, 400.0)),
        "medium" => Ok((720.0, 590.0, 420.0, 500.0)),
        "large" => Ok((900.0, 738.0, 525.0, 625.0)),
        _ => Err("不支持的界面大小".into()),
    }
}

fn apply_window_scale(app: &AppHandle, scale: &str) -> Result<(), String> {
    let (width, height, min_width, min_height) = window_dimensions(scale)?;
    let window = app.get_webview_window("main").ok_or("找不到主窗口")?;
    window
        .set_min_size(Some(LogicalSize::new(min_width, min_height)))
        .map_err(|error| error.to_string())?;
    window
        .set_size(LogicalSize::new(width, height))
        .map_err(|error| error.to_string())
}

fn show_main_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

fn copy_detected() {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    if now.saturating_sub(LAST_COPY_TICK.swap(now, Ordering::Relaxed)) < 250 { return; }
    thread::spawn(|| {
        thread::sleep(Duration::from_millis(180));
        let mut text = None;
        for _ in 0..5 {
            if let Ok(mut clipboard) = arboard::Clipboard::new() {
                if let Ok(value) = clipboard.get_text() {
                    text = Some(value);
                    break;
                }
            }
            thread::sleep(Duration::from_millis(60));
        }
        if let (Some(app), Some(value)) = (APP.get(), text) {
            show_main_window(app);
            let _ = app.emit("clipboard-text", value);
        }
    });
}

unsafe extern "system" fn keyboard_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 && MONITOR_COPY.load(Ordering::Relaxed) && (wparam as u32 == WM_KEYDOWN || wparam as u32 == WM_SYSKEYDOWN) {
        let keyboard = &*(lparam as *const KBDLLHOOKSTRUCT);
        if keyboard.vkCode == VK_C && GetAsyncKeyState(VK_CONTROL as i32) < 0 {
            copy_detected();
        }
    }
    CallNextHookEx(std::ptr::null_mut(), code, wparam, lparam)
}

fn start_windows_listeners() {
    let (sender, receiver) = mpsc::sync_channel(1);
    thread::spawn(move || unsafe {
        let registered = RegisterHotKey(std::ptr::null_mut(), HOTKEY_ID, MOD_CONTROL | MOD_ALT, VK_ESCAPE as u32) != 0;
        HOTKEY_READY.store(registered, Ordering::Relaxed);
        let _ = sender.send(registered);

        let module = GetModuleHandleW(std::ptr::null());
        let hook: HHOOK = SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook), module, 0);
        let mut message: MSG = std::mem::zeroed();
        while GetMessageW(&mut message, std::ptr::null_mut(), 0, 0) > 0 {
            if message.message == WM_HOTKEY && message.wParam == HOTKEY_ID as usize {
                STOP_REQUESTED.store(true, Ordering::Relaxed);
                if let Some(app) = APP.get() { let _ = app.emit("stop-requested", ()); }
            }
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        if !hook.is_null() { UnhookWindowsHookEx(hook); }
        if registered { UnregisterHotKey(std::ptr::null_mut(), HOTKEY_ID); }
    });
    let _ = receiver.recv_timeout(Duration::from_secs(1));
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![initial_state, set_monitor_copy, set_ui_scale, stop_typing, send_text])
        .setup(|app| {
            MONITOR_COPY.store(load_monitor_copy(), Ordering::Relaxed);
            let _ = APP.set(app.handle().clone());
            apply_window_scale(app.handle(), &load_ui_scale())?;
            let arguments: Vec<String> = std::env::args().collect();
            if arguments.iter().any(|argument| argument == "--layout-test-min") {
                let scale = load_ui_scale();
                let (_, _, min_width, min_height) = window_dimensions(&scale)?;
                if let Some(window) = app.get_webview_window("main") {
                    window.set_size(LogicalSize::new(min_width, min_height))?;
                }
            } else if arguments.iter().any(|argument| argument == "--layout-test-narrow") {
                if let Some(window) = app.get_webview_window("main") {
                    window.set_size(LogicalSize::new(420.0, 650.0))?;
                }
            }
            start_windows_listeners();

            let show_item = MenuItem::with_id(app, "show", "显示窗口", true, None::<&str>)?;
            let exit_item = MenuItem::with_id(app, "exit", "退出", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show_item, &exit_item])?;
            let icon = app.default_window_icon().cloned().expect("application icon");
            TrayIconBuilder::new()
                .icon(icon)
                .tooltip("键盘输入桥")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "show" => show_main_window(app),
                    "exit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                        show_main_window(tray.app_handle());
                    }
                })
                .build(app)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .run(tauri::generate_context!())
        .expect("failed to run KeyboardBridge");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_plan_normalizes_crlf_once() {
        let plan = build_plan("a\r\nb\nc", false);
        assert_eq!(plan.units.iter().collect::<String>(), "a b c");
        assert_eq!(plan.replaced_newlines, 2);
    }

    #[test]
    fn physical_mapping_matches_windows_keys() {
        assert_eq!(map_physical('a').unwrap().virtual_key, 0x41);
        assert!(map_physical('A').unwrap().shift);
        assert_eq!(map_physical('.').unwrap().virtual_key, 0xBE);
        assert!(map_physical('$').unwrap().shift);
    }

    #[test]
    fn native_input_layout_is_correct() {
        assert_eq!(size_of::<INPUT>(), if size_of::<usize>() == 8 { 40 } else { 28 });
    }

    #[test]
    fn scale_presets_have_increasing_window_sizes() {
        let small = window_dimensions("small").unwrap();
        let medium = window_dimensions("medium").unwrap();
        let large = window_dimensions("large").unwrap();
        assert!(small.0 < medium.0 && medium.0 < large.0);
        assert!(small.1 < medium.1 && medium.1 < large.1);
        assert!(small.2 < medium.2 && medium.2 < large.2);
        assert!(small.3 < medium.3 && medium.3 < large.3);
        assert!(window_dimensions("unknown").is_err());
    }
}
