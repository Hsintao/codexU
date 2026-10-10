//! The same packaged local catalog used by the macOS app. No network requests.
use std::collections::HashMap;
use std::sync::OnceLock;

use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::models::TokenBreakdown;

const CATALOG: &str = include_str!("../../../../Resources/model-pricing.json");

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelTokenPrice {
    pub model: String,
    aliases: Vec<String>,
    pub input_per_million: f64,
    pub cached_input_per_million: f64,
    pub cache_write_input_per_million: f64,
    pub output_per_million: f64,
    tier_multipliers: HashMap<String, f64>,
    long_context_threshold: Option<i64>,
    long_context_input_multiplier: Option<f64>,
    long_context_output_multiplier: Option<f64>,
    fast_supports_long_context: bool,
    pub uses_reference_pricing: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Catalog {
    schema_version: u32,
    reference_model: String,
    models: Vec<ModelTokenPrice>,
}

fn catalog() -> &'static Catalog {
    static VALUE: OnceLock<Catalog> = OnceLock::new();
    VALUE.get_or_init(|| {
        let value: Catalog = serde_json::from_str(CATALOG).expect("valid packaged pricing catalog");
        assert_eq!(value.schema_version, 1);
        assert!(value
            .models
            .iter()
            .any(|p| p.model == value.reference_model));
        value
    })
}

pub fn catalog_fingerprint() -> String {
    format!("{:x}", Sha256::digest(CATALOG.as_bytes()))
}

fn matches(price: &ModelTokenPrice, model: &str) -> bool {
    std::iter::once(&price.model)
        .chain(&price.aliases)
        .any(|name| {
            if model == name {
                return true;
            }
            let Some(suffix) = model.strip_prefix(&format!("{name}-")) else {
                return false;
            };
            if name.starts_with("claude-") {
                return !suffix.is_empty()
                    && suffix
                        .bytes()
                        .all(|c| c.is_ascii_digit() || c == b'-' || c == b'.');
            }
            suffix.len() == 10
                && suffix.bytes().enumerate().all(|(i, c)| {
                    if i == 4 || i == 7 {
                        c == b'-'
                    } else {
                        c.is_ascii_digit()
                    }
                })
        })
}

#[derive(Debug, Clone, Copy)]
pub struct CostEstimate {
    pub usd: f64,
    pub uses_reference_pricing: bool,
}

pub fn estimate(
    tokens: &TokenBreakdown,
    model: Option<&str>,
    service_tier: Option<&str>,
) -> CostEstimate {
    let model = model.unwrap_or("").trim().to_lowercase();
    let catalog = catalog();
    let known = catalog.models.iter().find(|p| matches(p, &model));
    let price = known.unwrap_or_else(|| {
        catalog
            .models
            .iter()
            .find(|p| p.model == catalog.reference_model)
            .unwrap()
    });
    let tier = service_tier.unwrap_or("default").trim().to_lowercase();
    let tier = if tier.is_empty() { "default" } else { &tier };
    let multiplier = price.tier_multipliers.get(tier);
    let input = tokens.input_tokens.max(0);
    let cached = tokens.cached_input_tokens.max(0).min(input);
    let write = tokens.cache_write_input_tokens.max(0).min(input - cached);
    let long = price
        .long_context_threshold
        .is_some_and(|threshold| input > threshold);
    let fast = matches!(tier, "priority" | "fast");
    let tier_multiplier = if long && fast && !price.fast_supports_long_context {
        1.0
    } else {
        multiplier.copied().unwrap_or(1.0)
    };
    let input_multiplier = tier_multiplier
        * if long {
            price.long_context_input_multiplier.unwrap_or(1.0)
        } else {
            1.0
        };
    let output_multiplier = tier_multiplier
        * if long {
            price.long_context_output_multiplier.unwrap_or(1.0)
        } else {
            1.0
        };
    CostEstimate {
        usd: ((input - cached - write) as f64 * price.input_per_million
            + cached as f64 * price.cached_input_per_million
            + write as f64 * price.cache_write_input_per_million)
            / 1_000_000.0
            * input_multiplier
            + tokens.output_tokens.max(0) as f64 / 1_000_000.0
                * price.output_per_million
                * output_multiplier,
        uses_reference_pricing: known.is_none()
            || price.uses_reference_pricing
            || multiplier.is_none(),
    }
}
