use chrono::{TimeZone, Utc};
use codexu_core::{model_pricing, readers::CodexTranscriptReader, TokenBreakdown};
use serde::Deserialize;

#[derive(Deserialize)]
struct Vector {
    name: String,
    model: String,
    input: i64,
    cached: i64,
    write: i64,
    output: i64,
    tier: Option<String>,
    expected: f64,
    reference: bool,
}

#[tokio::test]
async fn interleaved_turn_settings_preserve_model_and_incremental_cache_writes() {
    let temp = tempfile::tempdir().unwrap();
    let sessions = temp.path().join("sessions");
    std::fs::create_dir(&sessions).unwrap();
    let path = sessions.join("rollout-settings.jsonl");
    let now = Utc.with_ymd_and_hms(2026, 10, 11, 0, 0, 0).unwrap();
    let records = [
        serde_json::json!({"type":"session_meta","payload":{"id":"settings","cwd":"fixture"}}),
        serde_json::json!({"type":"turn_context","payload":{"model":"gpt-6.1-sol","turn_id":"a"}}),
        serde_json::json!({"type":"event_msg","payload":{"type":"thread_settings_applied","turn_id":"a","thread_settings":{"service_tier":"priority"}}}),
        serde_json::json!({"type":"event_msg","payload":{"type":"token_count","turn_id":"a","info":{"total_token_usage":{"input_tokens":100000,"cached_input_tokens":40000,"cache_write_input_tokens":10000,"output_tokens":10000,"total_tokens":110000}}}}),
        serde_json::json!({"type":"turn_context","payload":{"model":"gpt-6-sol","turn_id":"b","service_tier":"flex"}}),
        serde_json::json!({"type":"event_msg","payload":{"type":"token_count","turn_id":"b","info":{"total_token_usage":{"input_tokens":200000,"cached_input_tokens":80000,"cache_write_input_tokens":20000,"output_tokens":20000,"total_tokens":220000}}}}),
        // A settings event for a previously observed turn must not replace its model with b's.
        serde_json::json!({"type":"event_msg","payload":{"type":"thread_settings_applied","turn_id":"a","thread_settings":{"service_tier":"priority"}}}),
        serde_json::json!({"type":"event_msg","payload":{"type":"token_count","turn_id":"a","info":{"total_token_usage":{"input_tokens":300000,"cached_input_tokens":120000,"cache_write_input_tokens":30000,"output_tokens":30000,"total_tokens":330000}}}}),
    ];
    let lines: Vec<String> = records
        .into_iter()
        .enumerate()
        .map(|(i, mut v)| {
            v["timestamp"] = format!("2026-10-10T00:00:{i:02}Z").into();
            v.to_string() + "\n"
        })
        .collect();
    std::fs::write(&path, lines[..6].concat()).unwrap();
    let reader = CodexTranscriptReader::new(temp.path().join("incremental-cache"));
    let first = reader
        .load_local_usage(temp.path(), now)
        .await
        .unwrap()
        .unwrap();
    assert!(
        (first
            .detailed_usage
            .as_ref()
            .unwrap()
            .month
            .estimated_cost_usd
            - 0.5745)
            .abs()
            < 1e-10
    );
    let bytes = lines.concat();
    std::fs::write(&path, &bytes).unwrap();
    let incremental = reader
        .load_local_usage(temp.path(), now)
        .await
        .unwrap()
        .unwrap();
    let month = &incremental.detailed_usage.as_ref().unwrap().month;
    assert!(
        (month.estimated_cost_usd - 1.0325).abs() < 1e-10,
        "{}",
        month.estimated_cost_usd
    );
    assert_eq!(month.tokens.total_tokens, 330000);
    assert_eq!(month.tokens.cache_write_input_tokens, 30000);
    assert!(!month.uses_reference_pricing);
    let full = CodexTranscriptReader::new(temp.path().join("full-cache"))
        .load_local_usage(temp.path(), now)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(incremental, full);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), bytes);
}

#[test]
fn shared_cross_platform_pricing_vectors() {
    let vectors: Vec<Vector> = serde_json::from_str(include_str!(
        "../../../../Resources/model-pricing-vectors.json"
    ))
    .unwrap();
    for v in vectors {
        let tokens = TokenBreakdown {
            input_tokens: v.input,
            cached_input_tokens: v.cached,
            cache_write_input_tokens: v.write,
            output_tokens: v.output,
            reasoning_output_tokens: 500,
            total_tokens: v.input + v.output,
        };
        let value = model_pricing::estimate(&tokens, Some(&v.model), v.tier.as_deref());
        assert!(
            (value.usd - v.expected).abs() < 1e-10,
            "{}: {} != {}",
            v.name,
            value.usd,
            v.expected
        );
        assert_eq!(value.uses_reference_pricing, v.reference, "{}", v.name);
    }
}

#[tokio::test]
async fn billing_metadata_and_stale_derived_index_rebuild_without_source_changes() {
    let temp = tempfile::tempdir().unwrap();
    let cache = temp.path().join("cache");
    let sessions = temp.path().join("sessions");
    std::fs::create_dir(&sessions).unwrap();
    let path = sessions.join("rollout-pricing.jsonl");
    let date = "2026-10-10T00:00:00Z";
    let records = [
        serde_json::json!({"timestamp":date,"type":"session_meta","payload":{"id":"pricing","cwd":"fixture"}}),
        serde_json::json!({"timestamp":date,"type":"turn_context","payload":{"model":"gpt-6.1-sol","turn_id":"a","service_tier":"priority"}}),
        serde_json::json!({"timestamp":date,"type":"event_msg","payload":{"type":"token_count","turn_id":"a","info":{"last_token_usage":{"input_tokens":100000,"cached_input_tokens":40000,"cache_write_input_tokens":10000,"output_tokens":10000,"reasoning_output_tokens":500,"total_tokens":110000}}}}),
        serde_json::json!({"timestamp":date,"type":"turn_context","payload":{"model":"future-model","turn_id":"b","service_tier":"default"}}),
        serde_json::json!({"timestamp":date,"type":"event_msg","payload":{"type":"token_count","turn_id":"b","info":{"last_token_usage":{"input_tokens":100000,"cached_input_tokens":40000,"cache_write_input_tokens":10000,"output_tokens":10000,"total_tokens":110000}}}}),
    ];
    let bytes = records
        .iter()
        .map(|r| r.to_string() + "\n")
        .collect::<String>();
    std::fs::write(&path, &bytes).unwrap();
    let reader = CodexTranscriptReader::new(&cache);
    let now = Utc.with_ymd_and_hms(2026, 10, 11, 0, 0, 0).unwrap();
    let first = reader
        .load_local_usage(temp.path(), now)
        .await
        .unwrap()
        .unwrap();
    let detailed = first.detailed_usage.as_ref().unwrap();
    assert_eq!(first.lifetime_tokens, 220000);
    assert!((detailed.month.estimated_cost_usd - 1.078).abs() < 1e-10);
    assert!(detailed.month.uses_reference_pricing);
    assert_eq!(detailed.month.tokens.cache_write_input_tokens, 20000);
    let db_path = codexu_core::readers::codex_history_index::database_path(&cache);
    for obsolete_schema in [1, 2] {
        let db = rusqlite::Connection::open(&db_path).unwrap();
        db.execute_batch(&format!("PRAGMA user_version={obsolete_schema}; UPDATE fact SET payload='obsolete derived payload';"))
            .unwrap();
        drop(db);
        let rebuilt = reader
            .load_local_usage(temp.path(), now)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(first, rebuilt);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), bytes);
        let warm = reader
            .load_local_usage(temp.path(), now)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(rebuilt, warm);
    }
    let db = rusqlite::Connection::open(&db_path).unwrap();
    let version: i64 = db
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, 3);
    db.execute_batch("PRAGMA user_version=999;").unwrap();
    drop(db);
    assert!(reader.load_local_usage(temp.path(), now).await.is_err());
    let db = rusqlite::Connection::open(db_path).unwrap();
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        999
    );
}
