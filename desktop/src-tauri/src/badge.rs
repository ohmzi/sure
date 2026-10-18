use serde::Deserialize;
use tauri::Listener;

#[derive(Deserialize)]
struct BadgePayload {
    count: i64,
}

pub fn register(app: &tauri::AppHandle) {
    #[cfg(target_os = "macos")]
    let handle = app.clone();
    app.listen("bridge://badge", move |event| {
        if let Ok(p) = serde_json::from_str::<BadgePayload>(event.payload()) {
            #[cfg(target_os = "macos")]
            {
                let label = if p.count > 0 {
                    Some(p.count.to_string())
                } else {
                    None
                };
                use tauri::Manager;
                if let Some(w) = handle.get_webview_window("main") {
                    let _ = w.set_badge_label(label);
                }
            }
            // No dock badge outside macOS; read the payload so it is not unused.
            #[cfg(not(target_os = "macos"))]
            let _ = p.count;
        }
    });
}
