use std::alloc::{GlobalAlloc, Layout, System};
use std::fs::File;
use std::io::Write;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

use chrono::{TimeZone, Utc};
use codexu_core::readers::{CodexDashboardProvider, InferencePerformanceReader};
use tempfile::tempdir;

struct TrackingAllocator;

static CURRENT_BYTES: AtomicUsize = AtomicUsize::new(0);
static PEAK_BYTES: AtomicUsize = AtomicUsize::new(0);

fn record_allocation(size: usize) {
    let current = CURRENT_BYTES.fetch_add(size, Ordering::Relaxed) + size;
    PEAK_BYTES.fetch_max(current, Ordering::Relaxed);
}

unsafe impl GlobalAlloc for TrackingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let pointer = unsafe { System.alloc(layout) };
        if !pointer.is_null() {
            record_allocation(layout.size());
        }
        pointer
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let pointer = unsafe { System.alloc_zeroed(layout) };
        if !pointer.is_null() {
            record_allocation(layout.size());
        }
        pointer
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        unsafe { System.dealloc(pointer, layout) };
        CURRENT_BYTES.fetch_sub(layout.size(), Ordering::Relaxed);
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let resized = unsafe { System.realloc(pointer, layout, new_size) };
        if !resized.is_null() {
            if new_size >= layout.size() {
                record_allocation(new_size - layout.size());
            } else {
                CURRENT_BYTES.fetch_sub(layout.size() - new_size, Ordering::Relaxed);
            }
        }
        resized
    }
}

#[global_allocator]
static ALLOCATOR: TrackingAllocator = TrackingAllocator;

#[tokio::test]
async fn oversized_rollout_line_keeps_peak_allocation_bounded_and_parses_following_events() {
    let temp = tempdir().unwrap();
    let archived = temp.path().join("archived_sessions");
    let cache = temp.path().join("cache");
    std::fs::create_dir_all(&archived).unwrap();

    let rollout = archived.join("rollout-extreme.jsonl");
    let mut file = File::create(&rollout).unwrap();
    let chunk = [b'x'; 64 * 1024];
    for _ in 0..(48 * 1024 / 64) {
        file.write_all(&chunk).unwrap();
    }
    file.write_all(b"\n").unwrap();
    for line in [
        r#"{"timestamp":"2026-08-05T14:59:50.000Z","type":"session_meta","payload":{"id":"extreme-thread"}}"#,
        r#"{"timestamp":"2026-08-05T15:00:00.000Z","type":"turn_context","payload":{"turn_id":"turn-extreme","model":"gpt-5","effort":"high"}}"#,
        r#"{"timestamp":"2026-08-05T15:00:01.000Z","type":"response_item","payload":{"type":"agent_message","role":"assistant"}}"#,
        r#"{"timestamp":"2026-08-05T15:00:04.000Z","type":"event_msg","payload":{"type":"token_count","turn_id":"turn-extreme","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":40,"reasoning_output_tokens":10,"total_tokens":140}}}}"#,
    ] {
        file.write_all(line.as_bytes()).unwrap();
        file.write_all(b"\n").unwrap();
    }
    file.flush().unwrap();
    drop(file);

    let baseline_bytes = CURRENT_BYTES.load(Ordering::Relaxed);
    PEAK_BYTES.store(baseline_bytes, Ordering::Relaxed);
    let started = Instant::now();
    let history = InferencePerformanceReader::new(&cache)
        .load(
            temp.path(),
            Utc.with_ymd_and_hms(2026, 8, 5, 15, 0, 10).unwrap(),
        )
        .await
        .unwrap()
        .expect("valid events after the oversized line remain readable");
    let elapsed = started.elapsed();
    let peak_growth = PEAK_BYTES
        .load(Ordering::Relaxed)
        .saturating_sub(baseline_bytes);

    assert_eq!(
        history.today.as_ref().unwrap().total_call_count,
        1,
        "discarding an oversized line must not discard later valid events"
    );
    assert!(
        peak_growth < 16 * 1024 * 1024,
        "48 MiB input line must not be held in memory; observed peak growth: {peak_growth} bytes"
    );
    eprintln!(
        "extreme_streaming_fixture bytes={} elapsed_ms={} peak_growth_bytes={}",
        std::fs::metadata(&rollout).unwrap().len(),
        elapsed.as_millis(),
        peak_growth
    );

    drop(history);
    // A valid image output must remain usable by the complete-history reader,
    // while its body must not turn into a 48 MiB in-memory JSON value.
    let mut image = File::create(&rollout).unwrap();
    image.write_all(br#"{"timestamp":"2026-08-05T14:59:50Z","type":"response_item","payload":{"type":"custom_tool_call_output","output":"data:image/png;base64,"#).unwrap();
    for _ in 0..(48 * 1024 / 64) {
        image.write_all(&chunk).unwrap();
    }
    image.write_all(b"\"}}\n").unwrap();
    image.write_all(br#"{"timestamp":"2026-08-05T15:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":40,"total_tokens":140}}}}
"#).unwrap();
    drop(image);
    let image_baseline = CURRENT_BYTES.load(Ordering::Relaxed);
    PEAK_BYTES.store(image_baseline, Ordering::Relaxed);
    let image_usage = codexu_core::readers::CodexTranscriptReader::new(&cache)
        .load_local_usage(
            temp.path(),
            Utc.with_ymd_and_hms(2026, 8, 5, 15, 0, 10).unwrap(),
        )
        .await
        .unwrap()
        .unwrap();
    let image_growth = PEAK_BYTES
        .load(Ordering::Relaxed)
        .saturating_sub(image_baseline);
    assert_eq!(image_usage.lifetime_tokens, 140);
    assert!(
        image_growth < 16 * 1024 * 1024,
        "large image history allocated {image_growth} bytes"
    );
    eprintln!("large_image_history peak_growth_bytes={image_growth}");
    drop(image_usage);
    let refresh_temp = tempdir().unwrap();
    let refresh_archived = refresh_temp.path().join("archived_sessions");
    let refresh_cache = refresh_temp.path().join("cache");
    std::fs::create_dir_all(&refresh_archived).unwrap();
    for index in 0..128 {
        let turn_id = format!("turn-{index}");
        let contents = [
            format!(
                r#"{{"timestamp":"2026-08-05T14:59:50.000Z","type":"session_meta","payload":{{"id":"refresh-{index}","cwd":"C:\\workspace"}}}}"#
            ),
            format!(
                r#"{{"timestamp":"2026-08-05T15:00:00.000Z","type":"turn_context","payload":{{"turn_id":"{turn_id}","model":"gpt-5","effort":"high"}}}}"#
            ),
            r#"{"timestamp":"2026-08-05T15:00:01.000Z","type":"response_item","payload":{"type":"agent_message","role":"assistant"}}"#.to_string(),
            format!(
                r#"{{"timestamp":"2026-08-05T15:00:04.000Z","type":"event_msg","payload":{{"type":"token_count","turn_id":"{turn_id}","info":{{"last_token_usage":{{"input_tokens":100,"cached_input_tokens":0,"output_tokens":40,"reasoning_output_tokens":10,"total_tokens":140}}}}}}}}"#
            ),
        ]
        .join("\n");
        std::fs::write(
            refresh_archived.join(format!("rollout-refresh-{index:03}.jsonl")),
            contents,
        )
        .unwrap();
    }

    let provider = CodexDashboardProvider::new(refresh_temp.path(), &refresh_cache);
    let refresh_now = Utc.with_ymd_and_hms(2026, 8, 5, 15, 0, 10).unwrap();
    let first_refresh_baseline = CURRENT_BYTES.load(Ordering::Relaxed);
    PEAK_BYTES.store(first_refresh_baseline, Ordering::Relaxed);
    let first_refresh_started = Instant::now();
    let first_refresh = provider
        .load_dashboard_snapshot(refresh_now)
        .await
        .unwrap()
        .expect("representative refresh");
    let first_refresh_elapsed = first_refresh_started.elapsed();
    let first_refresh_peak = PEAK_BYTES
        .load(Ordering::Relaxed)
        .saturating_sub(first_refresh_baseline);
    assert_eq!(
        first_refresh
            .codex
            .snapshot
            .local
            .as_ref()
            .unwrap()
            .inference_performance
            .as_ref()
            .unwrap()
            .today
            .as_ref()
            .unwrap()
            .total_call_count,
        128
    );
    drop(first_refresh);

    let cached_refresh_baseline = CURRENT_BYTES.load(Ordering::Relaxed);
    PEAK_BYTES.store(cached_refresh_baseline, Ordering::Relaxed);
    let cached_refresh_started = Instant::now();
    let cached_refresh = provider
        .load_dashboard_snapshot(refresh_now)
        .await
        .unwrap()
        .expect("cached representative refresh");
    let cached_refresh_elapsed = cached_refresh_started.elapsed();
    let cached_refresh_peak = PEAK_BYTES
        .load(Ordering::Relaxed)
        .saturating_sub(cached_refresh_baseline);
    assert!(cached_refresh.codex.snapshot.local.is_some());
    assert!(first_refresh_peak < 32 * 1024 * 1024);
    assert!(cached_refresh_peak < 32 * 1024 * 1024);
    eprintln!(
        "representative_refresh_fixture files=128 first_ms={} first_peak_growth_bytes={} cached_ms={} cached_peak_growth_bytes={}",
        first_refresh_elapsed.as_millis(),
        first_refresh_peak,
        cached_refresh_elapsed.as_millis(),
        cached_refresh_peak
    );
}
