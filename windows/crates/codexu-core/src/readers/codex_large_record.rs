//! Validate large JSONL records while retaining only fields used by statistics.
//! Image data, message bodies and tool outputs are consumed without allocation.
use std::cell::Cell;
use std::io::{self, BufRead, Read};
use std::rc::Rc;

use serde::de::{DeserializeSeed, IgnoredAny, MapAccess, Visitor};
use serde_json::{Map, Value};

use super::common::MAX_LINE_BYTES;
use super::history_integrity::HistoryReadError;

struct Budget {
    remaining: Cell<usize>,
    active: Cell<bool>,
    exceeded: Cell<bool>,
}

struct RecordReader<'a, R> {
    reader: &'a mut R,
    budget: Rc<Budget>,
    bytes: u64,
    newline: bool,
}

impl<R: BufRead> Read for RecordReader<'_, R> {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        if self.newline || output.is_empty() {
            return Ok(0);
        }
        let buffer = self.reader.fill_buf()?;
        if buffer.is_empty() {
            return Ok(0);
        }
        if buffer[0] == b'\n' {
            self.reader.consume(1);
            self.bytes += 1;
            self.newline = true;
            return Ok(0);
        }
        let count = output.len().min(buffer.len());
        let count = buffer[..count]
            .iter()
            .position(|byte| *byte == b'\n')
            .unwrap_or(count);
        if self.budget.active.get() {
            let Some(remaining) = self.budget.remaining.get().checked_sub(count) else {
                self.budget.exceeded.set(true);
                return Err(io::Error::other("statistics metadata exceeds its budget"));
            };
            self.budget.remaining.set(remaining);
        }
        output[..count].copy_from_slice(&buffer[..count]);
        self.reader.consume(count);
        self.bytes += count as u64;
        Ok(count)
    }
}

struct Projection {
    budget: Rc<Budget>,
    payload: bool,
}

impl<'de> DeserializeSeed<'de> for Projection {
    type Value = Value;

    fn deserialize<D: serde::Deserializer<'de>>(self, decoder: D) -> Result<Value, D::Error> {
        decoder.deserialize_map(self)
    }
}

impl<'de> Visitor<'de> for Projection {
    type Value = Value;

    fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
        formatter.write_str("a Codex record object")
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Value, A::Error> {
        let mut result = Map::new();
        while let Some(key) = map.next_key::<String>()? {
            if !self.payload && key == "payload" {
                result.insert(
                    key,
                    map.next_value_seed(Projection {
                        budget: self.budget.clone(),
                        payload: true,
                    })?,
                );
            } else if (!self.payload && matches!(key.as_str(), "type" | "timestamp"))
                || (self.payload
                    && matches!(
                        key.as_str(),
                        "type"
                            | "timestamp"
                            | "id"
                            | "cwd"
                            | "forked_from_id"
                            | "model"
                            | "turn_id"
                            | "started_at"
                            | "completed_at"
                            | "duration_ms"
                            | "info"
                            | "name"
                            | "call_id"
                            | "arguments"
                            | "input"
                            | "cmd"
                            | "command"
                    ))
            {
                result.insert(key, map.next_value::<Value>()?);
            } else {
                self.budget.active.set(false);
                let ignored = map.next_value::<IgnoredAny>();
                self.budget.active.set(true);
                ignored?;
            }
        }
        Ok(Value::Object(result))
    }
}

pub(super) fn read<R: BufRead>(reader: &mut R) -> anyhow::Result<(Value, u64, bool)> {
    let budget = Rc::new(Budget {
        remaining: Cell::new(MAX_LINE_BYTES),
        active: Cell::new(true),
        exceeded: Cell::new(false),
    });
    let mut record = RecordReader {
        reader,
        budget: budget.clone(),
        bytes: 0,
        newline: false,
    };
    let parsed = (|| {
        let mut decoder = serde_json::Deserializer::from_reader(&mut record);
        let value = Projection {
            budget: budget.clone(),
            payload: false,
        }
        .deserialize(&mut decoder)?;
        decoder.end()?;
        Ok::<_, serde_json::Error>(value)
    })();
    let value = parsed.map_err(|error| {
        if budget.exceeded.get() {
            HistoryReadError::ResourceLimited
        } else if error.is_io() {
            HistoryReadError::Unavailable
        } else {
            HistoryReadError::InvalidRecord
        }
    })?;
    Ok((value, record.bytes, record.newline))
}
