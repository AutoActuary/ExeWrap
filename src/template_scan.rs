#[cfg(windows)]
use std::ffi::c_void;
#[cfg(not(windows))]
use std::sync::atomic::{AtomicU64, Ordering};

use crate::{Error, Result};

pub const SENTINEL_KEY_LEN: usize = 39;
pub const SPACED_SENTINEL_LEN: usize = SENTINEL_KEY_LEN + 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SourceRange {
    pub start: usize,
    pub end: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Sentinel {
    pub key: String,
    pub expression: String,
    pub source_range: SourceRange,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ScanResult {
    pub json: String,
    pub sentinels: Vec<Sentinel>,
}

pub trait SentinelSource {
    fn next(&mut self) -> Result<String>;
}

#[derive(Default)]
pub struct RandomSentinelSource;

impl SentinelSource for RandomSentinelSource {
    fn next(&mut self) -> Result<String> {
        let mut out = String::with_capacity(SENTINEL_KEY_LEN);
        out.push('1');
        let mut random = [0u8; 48];
        while out.len() < SENTINEL_KEY_LEN {
            fill_random(&mut random)?;
            for byte in random {
                if byte < 250 {
                    out.push(char::from(b'0' + (byte % 10)));
                    if out.len() == SENTINEL_KEY_LEN {
                        break;
                    }
                }
            }
        }
        Ok(out)
    }
}

#[cfg(windows)]
fn fill_random(output: &mut [u8]) -> Result<()> {
    let length = u32::try_from(output.len()).map_err(|_| Error::RandomGenerationFailed)?;
    // SAFETY: `output` is writable for exactly `length` bytes for the duration of the call.
    if unsafe { rtl_gen_random(output.as_mut_ptr().cast(), length) } == 0 {
        Err(Error::RandomGenerationFailed)
    } else {
        Ok(())
    }
}

#[cfg(not(windows))]
fn fill_random(output: &mut [u8]) -> Result<()> {
    static COUNTER: AtomicU64 = AtomicU64::new(0x9e37_79b9_7f4a_7c15);
    let mut value =
        COUNTER.fetch_add(0x9e37_79b9_7f4a_7c15, Ordering::Relaxed) ^ u64::from(std::process::id());
    for byte in output {
        value ^= value << 13;
        value ^= value >> 7;
        value ^= value << 17;
        *byte = value as u8;
    }
    Ok(())
}

#[cfg(windows)]
#[link(name = "advapi32")]
unsafe extern "system" {
    #[link_name = "SystemFunction036"]
    fn rtl_gen_random(output: *mut c_void, length: u32) -> u8;
}

pub fn scan_with_random_sentinels(input: &str) -> Result<ScanResult> {
    scan(input, &mut RandomSentinelSource)
}

pub fn scan(input: &str, source: &mut impl SentinelSource) -> Result<ScanResult> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut sentinels = Vec::new();
    let mut index = 0;

    while index < bytes.len() {
        if bytes[index..].starts_with(b"@@{") {
            out.extend_from_slice(b"@{");
            index += 3;
            continue;
        }

        if bytes[index..].starts_with(b"@{") {
            let parsed = parse_template(bytes, index)?;
            let key = next_sentinel_key(source)?;
            let expression = input[parsed.expression_start..parsed.expression_end].to_owned();
            sentinels.push(Sentinel {
                key: key.clone(),
                expression,
                source_range: SourceRange {
                    start: parsed.template_start,
                    end: parsed.template_end,
                },
            });
            out.push(b' ');
            out.extend_from_slice(key.as_bytes());
            out.push(b' ');
            index = parsed.template_end;
            continue;
        }

        out.push(bytes[index]);
        index += 1;
    }

    Ok(ScanResult {
        // The scanner starts with valid UTF-8 and only inserts ASCII.
        json: String::from_utf8(out).expect("template scanner preserves UTF-8"),
        sentinels,
    })
}

#[derive(Clone, Copy)]
struct ParsedTemplate {
    expression_start: usize,
    expression_end: usize,
    template_start: usize,
    template_end: usize,
}

fn parse_template(input: &[u8], start: usize) -> Result<ParsedTemplate> {
    debug_assert!(input[start..].starts_with(b"@{"));

    let expression_start = start + 2;
    let mut index = expression_start;
    let mut in_template_string = false;
    let mut paren_depth = 0usize;

    while index < input.len() {
        let byte = input[index];
        if in_template_string {
            if byte == b'\\' {
                index = skip_template_string_escape(input, index)?;
                continue;
            }
            if byte == b'"' {
                in_template_string = false;
            }
            index += 1;
            continue;
        }

        match byte {
            b'"' => {
                in_template_string = true;
                index += 1;
            }
            b'(' => {
                paren_depth += 1;
                index += 1;
            }
            b')' => {
                paren_depth = paren_depth.saturating_sub(1);
                index += 1;
            }
            b'}' if paren_depth == 0 => {
                if index == expression_start {
                    return Err(Error::EmptyTemplateExpression);
                }
                return Ok(ParsedTemplate {
                    expression_start,
                    expression_end: index,
                    template_start: start,
                    template_end: index + 1,
                });
            }
            _ => index += 1,
        }
    }

    if in_template_string {
        Err(Error::UnclosedTemplateString)
    } else if paren_depth > 0 {
        Err(Error::UnclosedTemplateParenthesis)
    } else {
        Err(Error::UnclosedTemplateExpression)
    }
}

fn next_sentinel_key(source: &mut impl SentinelSource) -> Result<String> {
    let key = source.next()?;
    if !is_numeric_sentinel_key(&key) {
        return Err(Error::InvalidSentinelKey);
    }
    Ok(key)
}

fn skip_template_string_escape(input: &[u8], slash_index: usize) -> Result<usize> {
    let Some(&escaped) = input.get(slash_index + 1) else {
        return Err(Error::UnclosedTemplateString);
    };
    match escaped {
        b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't' => Ok(slash_index + 2),
        b'u' => {
            let Some(digits) = input.get(slash_index + 2..slash_index + 6) else {
                return Err(Error::InvalidTemplateStringEscape);
            };
            if digits.iter().all(u8::is_ascii_hexdigit) {
                Ok(slash_index + 6)
            } else {
                Err(Error::InvalidTemplateStringEscape)
            }
        }
        _ => Err(Error::InvalidTemplateStringEscape),
    }
}

pub fn is_numeric_sentinel_key(value: &str) -> bool {
    value.len() == SENTINEL_KEY_LEN
        && value.starts_with('1')
        && value.as_bytes()[1..].iter().all(u8::is_ascii_digit)
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY_1: &str = "100000000000000000000000000000000000001";
    const KEY_2: &str = "100000000000000000000000000000000000002";
    const KEY_3: &str = "100000000000000000000000000000000000003";

    struct DeterministicSentinels<'a> {
        values: &'a [&'a str],
        index: usize,
    }

    impl SentinelSource for DeterministicSentinels<'_> {
        fn next(&mut self) -> Result<String> {
            let value = self
                .values
                .get(self.index)
                .ok_or(Error::TestSentinelExhausted)?;
            self.index += 1;
            Ok((*value).to_owned())
        }
    }

    fn source<'a>(values: &'a [&'a str]) -> DeterministicSentinels<'a> {
        DeterministicSentinels { values, index: 0 }
    }

    #[test]
    fn literal_escape_emits_at_brace_without_a_sentinel() {
        let result = scan(
            r#"{"command":["@@{exe_dir}", @@{literal}]}"#,
            &mut source(&[KEY_1]),
        )
        .unwrap();
        assert_eq!(result.json, r#"{"command":["@{exe_dir}", @{literal}]}"#);
        assert!(result.sentinels.is_empty());
    }

    #[test]
    fn raw_template_expression_becomes_a_spaced_numeric_sentinel_value() {
        let result = scan(r#"{"command":[@{args}]}"#, &mut source(&[KEY_1])).unwrap();
        assert_eq!(result.json, format!(r#"{{"command":[ {KEY_1} ]}}"#));
        assert_eq!(result.sentinels[0].key, KEY_1);
        assert_eq!(result.sentinels[0].expression, "args");
        assert_eq!(
            result.sentinels[0].source_range,
            SourceRange { start: 12, end: 19 }
        );
    }

    #[test]
    fn templates_inside_json_strings_get_wrapper_spaces() {
        let result = scan(
            r#"{"path":"prefix @{exe_name} @{exe_dir} suffix"}"#,
            &mut source(&[KEY_1, KEY_2]),
        )
        .unwrap();
        assert_eq!(
            result.json,
            format!(r#"{{"path":"prefix  {KEY_1}   {KEY_2}  suffix"}}"#)
        );
        assert_eq!(result.sentinels.len(), 2);
    }

    #[test]
    fn single_template_inside_a_json_string_becomes_spaced_sentinel_text() {
        let result = scan(r#""@{exe_dir}""#, &mut source(&[KEY_1])).unwrap();
        assert_eq!(result.json, format!(r#"" {KEY_1} ""#));
    }

    #[test]
    fn template_mixed_with_literal_json_string_text_gets_wrapper_spaces() {
        let result = scan(r#""pre@{exe_dir}post""#, &mut source(&[KEY_1])).unwrap();
        assert_eq!(result.json, format!(r#""pre {KEY_1} post""#));
    }

    #[test]
    fn quoted_braces_and_nested_parentheses_do_not_end_expression() {
        let input = r#""@{env:"PATH}":prepend_env(exe_dir:parent:join("python}"))}""#;
        let result = scan(input, &mut source(&[KEY_1])).unwrap();
        assert_eq!(result.json, format!(r#"" {KEY_1} ""#));
        assert_eq!(
            result.sentinels[0].expression,
            r#"env:"PATH}":prepend_env(exe_dir:parent:join("python}"))"#
        );
    }

    #[test]
    fn json_escapes_inside_template_strings_are_consumed() {
        let result = scan(
            r#""@{exe_dir:join("quote\"brace}unicode\u007d")}""#,
            &mut source(&[KEY_1]),
        )
        .unwrap();
        assert_eq!(result.json, format!(r#"" {KEY_1} ""#));
        assert_eq!(
            result.sentinels[0].expression,
            r#"exe_dir:join("quote\"brace}unicode\u007d")"#
        );
    }

    #[test]
    fn scanner_does_not_retry_generated_keys_found_in_user_text() {
        let input = format!(r#"{{"literal":"{KEY_1}","values":[@{{a}},@{{b}}]}}"#);
        let result = scan(&input, &mut source(&[KEY_1, KEY_2])).unwrap();
        assert_eq!(result.sentinels[0].key, KEY_1);
        assert_eq!(result.sentinels[1].key, KEY_2);
    }

    #[test]
    fn empty_template_expression_is_rejected() {
        assert!(matches!(
            scan("@{}", &mut source(&[KEY_1])),
            Err(Error::EmptyTemplateExpression)
        ));
    }

    #[test]
    fn unclosed_template_expression_is_rejected() {
        assert!(matches!(
            scan("@{args", &mut source(&[KEY_1])),
            Err(Error::UnclosedTemplateExpression)
        ));
    }

    #[test]
    fn unclosed_template_string_is_rejected() {
        assert!(matches!(
            scan(r#"@{join("x)}"#, &mut source(&[KEY_1])),
            Err(Error::UnclosedTemplateString)
        ));
    }

    #[test]
    fn unclosed_template_parenthesis_is_rejected() {
        assert!(matches!(
            scan(r#"@{join("x"}"#, &mut source(&[KEY_1])),
            Err(Error::UnclosedTemplateParenthesis)
        ));
    }

    #[test]
    fn invalid_json_string_escape_inside_a_template_is_rejected() {
        assert!(matches!(
            scan(r#""@{join("\q")}""#, &mut source(&[KEY_1])),
            Err(Error::InvalidTemplateStringEscape)
        ));
    }

    #[test]
    fn sentinel_source_rejects_malformed_numeric_keys() {
        assert!(matches!(
            scan(
                "@{args}",
                &mut source(&["11111111-1111-4111-8111-111111111111"])
            ),
            Err(Error::InvalidSentinelKey)
        ));
    }

    #[test]
    fn random_source_generates_numeric_keys() {
        let mut source = RandomSentinelSource;
        let key = source.next().unwrap();
        let second = source.next().unwrap();
        assert!(is_numeric_sentinel_key(&key));
        assert_eq!(key.len(), SENTINEL_KEY_LEN);
        assert_eq!(key.as_bytes()[0], b'1');
        assert_ne!(KEY_3, key);
        assert_ne!(key, second);
    }
}
