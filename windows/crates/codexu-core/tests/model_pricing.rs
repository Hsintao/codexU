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
    let db = rusqlite::Connection::open(&db_path).unwrap();
    db.execute_batch("PRAGMA user_version=1; UPDATE fact SET payload='obsolete derived payload';")
        .unwrap();
    drop(db);
    let second = reader
        .load_local_usage(temp.path(), now)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(first, second);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), bytes);
    let third = reader
        .load_local_usage(temp.path(), now)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(second, third);
    let db = rusqlite::Connection::open(&db_path).unwrap();
    let version: i64 = db
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, 2);
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
