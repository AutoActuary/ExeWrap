use std::collections::BTreeSet;
use std::ffi::{OsStr, OsString};

#[cfg(windows)]
use std::os::windows::ffi::OsStrExt;

use crate::{EnvMap, Error, Result};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Strictness {
    pub error_on_missing_env: bool,
    pub error_on_arg_out_of_bounds: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Metadata {
    pub exe_path: String,
    pub exe_dir: String,
    pub exe_filename: String,
    pub exe_filename_noext: String,
    pub exe_ext: String,
    pub exe_ext_dot: String,
    pub exe_drive: String,
    pub exe_root: String,
    pub args0: String,
    pub cwd: String,
    pub temp_dir: String,
    pub home_dir: String,
    pub appdata_dir: String,
    pub localappdata_dir: String,
    pub programdata_dir: String,
    pub program_files_dir: String,
    pub program_files_x86_dir: String,
    pub documents_dir: String,
    pub downloads_dir: String,
    pub desktop_dir: String,
    pub os: String,
    pub arch: String,
    pub dir_sep: String,
    pub path_sep: String,
}

pub struct EvalContext<'a> {
    pub metadata: &'a Metadata,
    pub env: &'a mut EnvMap,
    pub args: &'a [OsString],
    pub strictness: Strictness,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Value {
    String(String),
    Integer(usize),
    List(Vec<OsString>),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TokenTag {
    Identifier,
    Integer,
    String,
    Colon,
    OpenParen,
    CloseParen,
    OpenBracket,
    CloseBracket,
    Plus,
    Minus,
    Eof,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Token {
    pub tag: TokenTag,
    pub lexeme: String,
    pub offset: usize,
    pub integer: usize,
    pub string: String,
}

impl Token {
    fn punctuation(tag: TokenTag, byte: u8, offset: usize) -> Self {
        Self {
            tag,
            lexeme: char::from(byte).to_string(),
            offset,
            integer: 0,
            string: String::new(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Source {
    Base(String),
    Env(String),
    ArgsAll,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Argument {
    String(String),
    Integer(usize),
    Expression(Box<Expression>),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NamedTransform {
    pub name: String,
    pub argument: Option<Argument>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum IndexBase {
    Integer(i64),
    End,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct IndexExpression {
    pub base: IndexBase,
    pub offset: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SliceExpression {
    pub start: IndexExpression,
    pub step: Option<IndexExpression>,
    pub stop: IndexExpression,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Transform {
    Index(IndexExpression),
    Slice(SliceExpression),
    Named(NamedTransform),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Expression {
    pub source: Source,
    pub transforms: Vec<Transform>,
}

impl Expression {
    pub fn evaluate(&self, context: &mut EvalContext<'_>) -> Result<Value> {
        let mut value = evaluate_source(context, &self.source)?;
        for transform in &self.transforms {
            value = apply_transform(context, value, transform)?;
        }
        Ok(value)
    }
}

pub fn tokenize(input: &str) -> Result<Vec<Token>> {
    let mut tokenizer = Tokenizer { input, index: 0 };
    let mut tokens = Vec::new();
    loop {
        let token = tokenizer.next()?;
        let done = token.tag == TokenTag::Eof;
        tokens.push(token);
        if done {
            return Ok(tokens);
        }
    }
}

pub fn parse(input: &str) -> Result<Expression> {
    let mut parser = Parser {
        tokens: tokenize(input)?,
        index: 0,
    };
    let expression = parser.parse_expression()?;
    if parser.current().tag != TokenTag::Eof {
        return Err(Error::ExpectedEndOfExpression);
    }
    Ok(expression)
}

pub fn evaluate(input: &str, context: &mut EvalContext<'_>) -> Result<Value> {
    parse(input)?.evaluate(context)
}

struct Tokenizer<'a> {
    input: &'a str,
    index: usize,
}

impl Tokenizer<'_> {
    fn next(&mut self) -> Result<Token> {
        self.skip_whitespace();
        let start = self.index;
        let bytes = self.input.as_bytes();
        let Some(&byte) = bytes.get(self.index) else {
            return Ok(Token {
                tag: TokenTag::Eof,
                lexeme: String::new(),
                offset: self.input.len(),
                integer: 0,
                string: String::new(),
            });
        };

        let tag = match byte {
            b':' => Some(TokenTag::Colon),
            b'(' => Some(TokenTag::OpenParen),
            b')' => Some(TokenTag::CloseParen),
            b'[' => Some(TokenTag::OpenBracket),
            b']' => Some(TokenTag::CloseBracket),
            b'+' => Some(TokenTag::Plus),
            b'-' => Some(TokenTag::Minus),
            _ => None,
        };
        if let Some(tag) = tag {
            self.index += 1;
            return Ok(Token::punctuation(tag, byte, start));
        }

        match byte {
            b'"' => self.read_string(),
            b'0'..=b'9' => self.read_integer(),
            _ if is_ident_start(byte) => Ok(self.read_identifier()),
            _ => Err(Error::UnexpectedCharacter),
        }
    }

    fn skip_whitespace(&mut self) {
        while self
            .input
            .as_bytes()
            .get(self.index)
            .is_some_and(|byte| matches!(byte, b' ' | b'\t' | b'\r' | b'\n'))
        {
            self.index += 1;
        }
    }

    fn read_identifier(&mut self) -> Token {
        let start = self.index;
        self.index += 1;
        while self
            .input
            .as_bytes()
            .get(self.index)
            .is_some_and(|byte| is_ident_continue(*byte))
        {
            self.index += 1;
        }
        Token {
            tag: TokenTag::Identifier,
            lexeme: self.input[start..self.index].to_owned(),
            offset: start,
            integer: 0,
            string: String::new(),
        }
    }

    fn read_integer(&mut self) -> Result<Token> {
        let start = self.index;
        self.index += 1;
        while self
            .input
            .as_bytes()
            .get(self.index)
            .is_some_and(u8::is_ascii_digit)
        {
            self.index += 1;
        }
        let lexeme = &self.input[start..self.index];
        let integer = lexeme.parse::<usize>().map_err(|_| Error::Overflow)?;
        Ok(Token {
            tag: TokenTag::Integer,
            lexeme: lexeme.to_owned(),
            offset: start,
            integer,
            string: String::new(),
        })
    }

    fn read_string(&mut self) -> Result<Token> {
        let start = self.index;
        self.index += 1;
        let mut out = Vec::new();
        let bytes = self.input.as_bytes();

        while self.index < bytes.len() {
            match bytes[self.index] {
                b'"' => {
                    self.index += 1;
                    return Ok(Token {
                        tag: TokenTag::String,
                        lexeme: self.input[start..self.index].to_owned(),
                        offset: start,
                        integer: 0,
                        string: String::from_utf8(out).map_err(|_| Error::InvalidString)?,
                    });
                }
                b'\\' => {
                    self.index += 1;
                    let Some(&escaped) = bytes.get(self.index) else {
                        return Err(Error::UnterminatedString);
                    };
                    match escaped {
                        b'"' | b'\\' | b'/' => out.push(escaped),
                        b'b' => out.push(0x08),
                        b'f' => out.push(0x0c),
                        b'n' => out.push(b'\n'),
                        b'r' => out.push(b'\r'),
                        b't' => out.push(b'\t'),
                        b'u' => {
                            let Some(digits) = bytes.get(self.index + 1..self.index + 5) else {
                                return Err(Error::InvalidString);
                            };
                            let digits =
                                std::str::from_utf8(digits).map_err(|_| Error::InvalidString)?;
                            let codepoint = u32::from_str_radix(digits, 16)
                                .map_err(|_| Error::InvalidString)?;
                            let character =
                                char::from_u32(codepoint).ok_or(Error::InvalidString)?;
                            let mut buffer = [0u8; 4];
                            out.extend_from_slice(character.encode_utf8(&mut buffer).as_bytes());
                            self.index += 4;
                        }
                        _ => return Err(Error::InvalidString),
                    }
                    self.index += 1;
                }
                0x00..=0x1f => return Err(Error::InvalidString),
                byte => {
                    out.push(byte);
                    self.index += 1;
                }
            }
        }
        Err(Error::UnterminatedString)
    }
}

struct Parser {
    tokens: Vec<Token>,
    index: usize,
}

impl Parser {
    fn current(&self) -> &Token {
        &self.tokens[self.index]
    }

    fn advance(&mut self) -> Token {
        let token = self.current().clone();
        if self.index + 1 < self.tokens.len() {
            self.index += 1;
        }
        token
    }

    fn parse_expression(&mut self) -> Result<Expression> {
        let source = self.parse_source()?;
        let mut transforms = Vec::new();
        loop {
            match self.current().tag {
                TokenTag::Colon => {
                    self.advance();
                    transforms.push(self.parse_transform()?);
                }
                TokenTag::OpenBracket => transforms.push(self.parse_list_selector()?),
                _ => break,
            }
        }
        Ok(Expression { source, transforms })
    }

    fn parse_source(&mut self) -> Result<Source> {
        if self.current().tag != TokenTag::Identifier {
            return Err(Error::ExpectedIdentifier);
        }
        let token = self.advance();
        if token.lexeme == "env" {
            self.expect(TokenTag::OpenBracket)?;
            if self.current().tag != TokenTag::String {
                return Err(Error::ExpectedString);
            }
            let name = self.advance().string;
            self.expect(TokenTag::CloseBracket)?;
            return Ok(Source::Env(name));
        }
        if token.lexeme == "args" {
            return Ok(Source::ArgsAll);
        }
        Ok(Source::Base(token.lexeme))
    }

    fn parse_transform(&mut self) -> Result<Transform> {
        if self.current().tag != TokenTag::Identifier {
            return Err(Error::ExpectedIdentifier);
        }
        let name = self.advance().lexeme;
        let argument = if self.current().tag == TokenTag::OpenParen {
            self.advance();
            let argument = self.parse_argument()?;
            self.expect(TokenTag::CloseParen)?;
            Some(argument)
        } else {
            None
        };
        Ok(Transform::Named(NamedTransform { name, argument }))
    }

    fn parse_list_selector(&mut self) -> Result<Transform> {
        self.expect(TokenTag::OpenBracket)?;
        let first = self.parse_index_expression()?;
        if self.current().tag == TokenTag::CloseBracket {
            self.advance();
            return Ok(Transform::Index(first));
        }
        if self.current().tag != TokenTag::Colon {
            return Err(Error::ExpectedColonOrCloseBracket);
        }
        self.advance();
        let second = self.parse_index_expression()?;
        if self.current().tag == TokenTag::CloseBracket {
            self.advance();
            return Ok(Transform::Slice(SliceExpression {
                start: first,
                step: None,
                stop: second,
            }));
        }
        if self.current().tag != TokenTag::Colon {
            return Err(Error::ExpectedColonOrCloseBracket);
        }
        self.advance();
        let third = self.parse_index_expression()?;
        self.expect(TokenTag::CloseBracket)?;
        Ok(Transform::Slice(SliceExpression {
            start: first,
            step: Some(second),
            stop: third,
        }))
    }

    fn parse_index_expression(&mut self) -> Result<IndexExpression> {
        let leading_sign = match self.current().tag {
            TokenTag::Minus => {
                self.advance();
                -1
            }
            TokenTag::Plus => {
                self.advance();
                1
            }
            _ => 1,
        };

        let token = self.advance();
        let base = match token.tag {
            TokenTag::Integer => {
                let value = i64::try_from(token.integer).map_err(|_| Error::IntegerOutOfRange)?;
                IndexBase::Integer(leading_sign * value)
            }
            TokenTag::Identifier if leading_sign > 0 && token.lexeme == "end" => IndexBase::End,
            _ => return Err(Error::ExpectedIndexExpression),
        };
        let mut expression = IndexExpression { base, offset: 0 };

        while matches!(self.current().tag, TokenTag::Plus | TokenTag::Minus) {
            let sign = if self.advance().tag == TokenTag::Minus {
                -1
            } else {
                1
            };
            if self.current().tag != TokenTag::Integer {
                return Err(Error::ExpectedInteger);
            }
            let offset =
                i64::try_from(self.advance().integer).map_err(|_| Error::IntegerOutOfRange)?;
            expression.offset = expression
                .offset
                .checked_add(sign * offset)
                .ok_or(Error::IndexExpressionOverflow)?;
        }
        Ok(expression)
    }

    fn parse_argument(&mut self) -> Result<Argument> {
        match self.current().tag {
            TokenTag::String => Ok(Argument::String(self.advance().string)),
            TokenTag::Integer => Ok(Argument::Integer(self.advance().integer)),
            TokenTag::Identifier => Ok(Argument::Expression(Box::new(self.parse_expression()?))),
            _ => Err(Error::ExpectedArgument),
        }
    }

    fn expect(&mut self, tag: TokenTag) -> Result<()> {
        if self.current().tag == tag {
            self.advance();
            return Ok(());
        }
        Err(match tag {
            TokenTag::Identifier => Error::ExpectedIdentifier,
            TokenTag::Integer => Error::ExpectedInteger,
            TokenTag::String => Error::ExpectedString,
            TokenTag::Colon => Error::ExpectedColon,
            TokenTag::OpenParen => Error::ExpectedOpenParen,
            TokenTag::CloseParen => Error::ExpectedCloseParen,
            TokenTag::OpenBracket => Error::ExpectedOpenBracket,
            TokenTag::CloseBracket => Error::ExpectedCloseBracket,
            TokenTag::Plus => Error::ExpectedPlus,
            TokenTag::Minus => Error::ExpectedMinus,
            TokenTag::Eof => Error::ExpectedEndOfExpression,
        })
    }
}

fn evaluate_source(context: &mut EvalContext<'_>, source: &Source) -> Result<Value> {
    match source {
        Source::Base(name) => Ok(Value::String(resolve_base(context, name)?)),
        Source::Env(name) => Ok(Value::String(resolve_env(context, name)?)),
        Source::ArgsAll => Ok(Value::List(context.args.to_vec())),
    }
}

fn resolve_base(context: &EvalContext<'_>, name: &str) -> Result<String> {
    let metadata = context.metadata;
    let value = match name {
        "args_as_json" => return args_as_json(context),
        "exe_path" => &metadata.exe_path,
        "exe_dir" => &metadata.exe_dir,
        "exe_filename" => &metadata.exe_filename,
        "exe_filename_noext" => &metadata.exe_filename_noext,
        "exe_ext" => &metadata.exe_ext,
        "exe_ext_dot" => &metadata.exe_ext_dot,
        "exe_drive" => &metadata.exe_drive,
        "exe_root" => &metadata.exe_root,
        "args0" => &metadata.args0,
        "cwd" => &metadata.cwd,
        "temp_dir" => &metadata.temp_dir,
        "home_dir" => &metadata.home_dir,
        "appdata_dir" => &metadata.appdata_dir,
        "localappdata_dir" => &metadata.localappdata_dir,
        "programdata_dir" => &metadata.programdata_dir,
        "program_files_dir" => &metadata.program_files_dir,
        "program_files_x86_dir" => &metadata.program_files_x86_dir,
        "documents_dir" => &metadata.documents_dir,
        "downloads_dir" => &metadata.downloads_dir,
        "desktop_dir" => &metadata.desktop_dir,
        "os" => &metadata.os,
        "arch" => &metadata.arch,
        "dir_sep" => &metadata.dir_sep,
        "path_sep" => &metadata.path_sep,
        _ => return Err(Error::UnknownBase),
    };
    Ok(value.clone())
}

fn args_as_json(context: &EvalContext<'_>) -> Result<String> {
    let mut out = String::from("[");
    for (index, argument) in context.args.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        append_args_json_string(&mut out, argument)?;
    }
    out.push(']');
    Ok(out)
}

fn append_args_json_string(out: &mut String, input: &OsStr) -> Result<()> {
    out.push('"');
    #[cfg(windows)]
    {
        for unit in input.encode_wide() {
            if unit <= 0x7f {
                let byte = unit as u8;
                if byte < 0x20 || matches!(byte, b'"' | b'\'' | b'\\' | b'`' | b'$') {
                    append_json_unicode_escape(out, unit);
                } else {
                    out.push(char::from(byte));
                }
            } else {
                append_json_unicode_escape(out, unit);
            }
        }
    }
    #[cfg(not(windows))]
    {
        let input = input.to_str().ok_or(Error::ArgumentMustBeUnicode)?;
        for character in input.chars() {
            if character.is_ascii() {
                let byte = character as u8;
                if byte < 0x20 || matches!(byte, b'"' | b'\'' | b'\\' | b'`' | b'$') {
                    append_json_unicode_escape(out, u16::from(byte));
                } else {
                    out.push(character);
                }
            } else {
                let mut units = [0u16; 2];
                for unit in character.encode_utf16(&mut units).iter().copied() {
                    append_json_unicode_escape(out, unit);
                }
            }
        }
    }
    out.push('"');
    Ok(())
}

fn append_json_unicode_escape(out: &mut String, value: u16) {
    use std::fmt::Write;
    write!(out, "\\u{value:04x}").expect("writing to a String cannot fail");
}

fn resolve_env(context: &EvalContext<'_>, name: &str) -> Result<String> {
    match context.env.get_os(name) {
        Some(value) => value
            .to_str()
            .map(str::to_owned)
            .ok_or(Error::EnvironmentValueMustBeUnicode),
        None if context.strictness.error_on_missing_env => Err(Error::MissingEnvironmentVariable),
        None => Ok(String::new()),
    }
}

fn resolve_list_index(
    context: &EvalContext<'_>,
    items: &[OsString],
    expression: IndexExpression,
) -> Result<Value> {
    let index = evaluate_index_expression(expression, items.len())?;
    if index <= 0 {
        return Err(Error::IndexOutOfBounds);
    }
    if index > i64::try_from(items.len()).map_err(|_| Error::IndexExpressionOverflow)? {
        return if context.strictness.error_on_arg_out_of_bounds {
            Err(Error::ArgumentOutOfBounds)
        } else {
            Ok(Value::String(String::new()))
        };
    }
    items[(index - 1) as usize]
        .to_str()
        .map(|value| Value::String(value.to_owned()))
        .ok_or(Error::ArgumentMustBeUnicode)
}

fn resolve_list_slice(items: &[OsString], slice: SliceExpression) -> Result<Value> {
    let default_step = IndexExpression {
        base: IndexBase::Integer(1),
        offset: 0,
    };
    let step = evaluate_index_expression(slice.step.unwrap_or(default_step), items.len())?;
    if step == 0 {
        return Err(Error::ZeroSliceStep);
    }
    if items.is_empty() {
        return Ok(Value::List(Vec::new()));
    }

    let len = i64::try_from(items.len()).map_err(|_| Error::IndexExpressionOverflow)?;
    let start = evaluate_index_expression(slice.start, items.len())?;
    let stop = evaluate_index_expression(slice.stop, items.len())?;
    let mut out = Vec::new();

    if step > 0 {
        let mut index = start.max(1);
        let last = stop.min(len);
        while index <= last {
            out.push(items[(index - 1) as usize].clone());
            if step > last - index {
                break;
            }
            index += step;
        }
    } else {
        let mut index = start.min(len);
        let last = stop.max(1);
        while index >= last {
            out.push(items[(index - 1) as usize].clone());
            if step < last - index {
                break;
            }
            index += step;
        }
    }
    Ok(Value::List(out))
}

fn evaluate_index_expression(expression: IndexExpression, item_count: usize) -> Result<i64> {
    let base = match expression.base {
        IndexBase::Integer(value) => value,
        IndexBase::End => i64::try_from(item_count).map_err(|_| Error::IndexExpressionOverflow)?,
    };
    base.checked_add(expression.offset)
        .ok_or(Error::IndexExpressionOverflow)
}

fn apply_transform(
    context: &mut EvalContext<'_>,
    value: Value,
    transform: &Transform,
) -> Result<Value> {
    match transform {
        Transform::Index(expression) => match value {
            Value::List(items) => resolve_list_index(context, &items, *expression),
            _ => Err(Error::WrongTransformType),
        },
        Transform::Slice(slice) => match value {
            Value::List(items) => resolve_list_slice(&items, *slice),
            _ => Err(Error::WrongTransformType),
        },
        Transform::Named(named) => apply_named_transform(context, value, named),
    }
}

fn apply_named_transform(
    context: &mut EvalContext<'_>,
    value: Value,
    transform: &NamedTransform,
) -> Result<Value> {
    let name = transform.name.as_str();
    if is_no_arg_string_transform(name) || is_no_arg_path_transform(name) {
        expect_no_argument(transform.argument.as_ref())?;
        return Ok(Value::String(apply_string_like_no_arg(
            context,
            expect_string(value)?,
            name,
        )?));
    }

    match name {
        "join" => {
            let input = expect_string(value)?;
            let argument = argument_string(context, required_argument(transform)?)?;
            Ok(Value::String(join_path(context, &input, &argument)))
        }
        "prefix" => {
            let input = expect_string(value)?;
            let argument = argument_string(context, required_argument(transform)?)?;
            Ok(Value::String(format!("{argument}{input}")))
        }
        "suffix" => {
            let input = expect_string(value)?;
            let argument = argument_string(context, required_argument(transform)?)?;
            Ok(Value::String(format!("{input}{argument}")))
        }
        "prepend_env" => {
            let input = expect_string(value)?;
            let argument = argument_string(context, required_argument(transform)?)?;
            Ok(Value::String(prepend_env(context, &input, &argument)))
        }
        "append_env" => {
            let input = expect_string(value)?;
            let argument = argument_string(context, required_argument(transform)?)?;
            Ok(Value::String(append_env(context, &input, &argument)))
        }
        "remove_env" => {
            let input = expect_string(value)?;
            let argument = argument_string(context, required_argument(transform)?)?;
            Ok(Value::String(remove_env(context, &input, &argument)))
        }
        "unique_env" => {
            expect_no_argument(transform.argument.as_ref())?;
            let input = expect_string(value)?;
            Ok(Value::String(unique_env(context, &input)))
        }
        _ => Err(Error::UnknownTransform),
    }
}

fn required_argument(transform: &NamedTransform) -> Result<&Argument> {
    transform
        .argument
        .as_ref()
        .ok_or(Error::MissingTransformArgument)
}

fn apply_string_like_no_arg(
    context: &EvalContext<'_>,
    input: String,
    name: &str,
) -> Result<String> {
    Ok(match name {
        "parent" => path_parent(&input).to_owned(),
        "filename" => path_filename(&input).to_owned(),
        "filename_noext" => path_filename_no_ext(&input).to_owned(),
        "ext" => path_ext(&input, false).to_owned(),
        "ext_dot" => path_ext(&input, true).to_owned(),
        "drive" => path_drive(&input).to_owned(),
        "root" => path_root(&input).to_owned(),
        "normalize" => normalize_path(context, &input),
        "slash" => input.replace('\\', "/"),
        "backslash" => input.replace('/', "\\"),
        "lower" => String::from_utf8(
            input
                .bytes()
                .map(|byte| byte.to_ascii_lowercase())
                .collect(),
        )
        .expect("ASCII case conversion preserves UTF-8"),
        "upper" => String::from_utf8(
            input
                .bytes()
                .map(|byte| byte.to_ascii_uppercase())
                .collect(),
        )
        .expect("ASCII case conversion preserves UTF-8"),
        "trim" => input.trim_matches([' ', '\t', '\r', '\n']).to_owned(),
        "json" => json_escape(&input),
        _ => return Err(Error::UnknownTransform),
    })
}

fn expect_string(value: Value) -> Result<String> {
    match value {
        Value::String(value) => Ok(value),
        _ => Err(Error::WrongTransformType),
    }
}

fn expect_no_argument(argument: Option<&Argument>) -> Result<()> {
    if argument.is_some() {
        Err(Error::UnexpectedTransformArgument)
    } else {
        Ok(())
    }
}

fn argument_string(context: &mut EvalContext<'_>, argument: &Argument) -> Result<String> {
    match argument {
        Argument::String(value) => Ok(value.clone()),
        Argument::Integer(_) => Err(Error::WrongTransformType),
        Argument::Expression(expression) => expect_string(expression.evaluate(context)?),
    }
}

fn is_no_arg_path_transform(name: &str) -> bool {
    matches!(
        name,
        "parent"
            | "filename"
            | "filename_noext"
            | "ext"
            | "ext_dot"
            | "drive"
            | "root"
            | "normalize"
            | "slash"
            | "backslash"
    )
}

fn is_no_arg_string_transform(name: &str) -> bool {
    matches!(name, "lower" | "upper" | "trim" | "json")
}

fn json_escape(input: &str) -> String {
    let mut out = Vec::with_capacity(input.len());
    for byte in input.bytes() {
        match byte {
            b'"' => out.extend_from_slice(b"\\\""),
            b'\\' => out.extend_from_slice(b"\\\\"),
            b'\n' => out.extend_from_slice(b"\\n"),
            b'\r' => out.extend_from_slice(b"\\r"),
            b'\t' => out.extend_from_slice(b"\\t"),
            0x08 => out.extend_from_slice(b"\\b"),
            0x0c => out.extend_from_slice(b"\\f"),
            0x00..=0x1f => {
                use std::fmt::Write;
                write!(StringByteWriter(&mut out), "\\u{byte:04x}")
                    .expect("writing to a byte buffer cannot fail");
            }
            _ => out.push(byte),
        }
    }
    String::from_utf8(out).expect("JSON escaping preserves UTF-8")
}

struct StringByteWriter<'a>(&'a mut Vec<u8>);

impl std::fmt::Write for StringByteWriter<'_> {
    fn write_str(&mut self, value: &str) -> std::fmt::Result {
        self.0.extend_from_slice(value.as_bytes());
        Ok(())
    }
}

fn path_parent(input: &str) -> &str {
    let trimmed = trim_trailing_path_separators(input);
    let root_len = path_root_length(trimmed);
    if trimmed.len() <= root_len {
        return trimmed;
    }
    for index in (root_len..trimmed.len()).rev() {
        if is_path_separator(trimmed.as_bytes()[index]) {
            return &trimmed[..index.max(root_len)];
        }
    }
    "."
}

fn path_filename(input: &str) -> &str {
    let trimmed = trim_trailing_path_separators(input);
    let root_len = path_root_length(trimmed);
    if trimmed.len() <= root_len {
        return "";
    }
    for index in (root_len..trimmed.len()).rev() {
        if is_path_separator(trimmed.as_bytes()[index]) {
            return &trimmed[index + 1..];
        }
    }
    trimmed
}

fn path_filename_no_ext(input: &str) -> &str {
    let filename = path_filename(input);
    last_extension_dot(filename).map_or(filename, |index| &filename[..index])
}

fn path_ext(input: &str, with_dot: bool) -> &str {
    let filename = path_filename(input);
    last_extension_dot(filename).map_or("", |index| {
        if with_dot {
            &filename[index..]
        } else {
            &filename[index + 1..]
        }
    })
}

fn path_drive(input: &str) -> &str {
    let bytes = input.as_bytes();
    if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
        return &input[..2];
    }
    if bytes.len() >= 2 && is_path_separator(bytes[0]) && is_path_separator(bytes[1]) {
        return unc_share_end(input)
            .map(|end| trim_trailing_path_separators(&input[..end]))
            .unwrap_or("");
    }
    ""
}

fn path_root(input: &str) -> &str {
    &input[..path_root_length(input)]
}

fn path_root_length(input: &str) -> usize {
    let bytes = input.as_bytes();
    if bytes.len() >= 2 && is_path_separator(bytes[0]) && is_path_separator(bytes[1]) {
        return unc_share_end(input).unwrap_or(2);
    }
    if bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && is_path_separator(bytes[2])
    {
        return 3;
    }
    if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
        return 2;
    }
    if bytes.first().is_some_and(|byte| is_path_separator(*byte)) {
        return 1;
    }
    0
}

fn unc_share_end(input: &str) -> Option<usize> {
    let bytes = input.as_bytes();
    let mut parts_seen = 0;
    let mut index = 2;
    while index < bytes.len() {
        while index < bytes.len() && is_path_separator(bytes[index]) {
            index += 1;
        }
        if index >= bytes.len() {
            break;
        }
        parts_seen += 1;
        while index < bytes.len() && !is_path_separator(bytes[index]) {
            index += 1;
        }
        if parts_seen == 2 {
            return Some(if index < bytes.len() {
                index + 1
            } else {
                index
            });
        }
    }
    None
}

fn trim_trailing_path_separators(input: &str) -> &str {
    let mut end = input.len();
    while end > path_root_length(&input[..end]) && is_path_separator(input.as_bytes()[end - 1]) {
        end -= 1;
    }
    &input[..end]
}

fn last_extension_dot(filename: &str) -> Option<usize> {
    filename
        .as_bytes()
        .iter()
        .rposition(|byte| *byte == b'.')
        .filter(|index| *index != 0)
}

fn join_path(context: &EvalContext<'_>, base: &str, part: &str) -> String {
    if base.is_empty() {
        return trim_leading_path_separators(part).to_owned();
    }
    let trimmed_base = trim_trailing_path_separators(base);
    let trimmed_part = trim_leading_path_separators(part);
    if trimmed_part.is_empty() {
        return trimmed_base.to_owned();
    }
    let mut out = trimmed_base.to_owned();
    if out
        .as_bytes()
        .last()
        .is_none_or(|byte| !is_path_separator(*byte))
    {
        out.push(preferred_dir_sep(context, trimmed_base));
    }
    out.push_str(trimmed_part);
    out
}

fn trim_leading_path_separators(input: &str) -> &str {
    let start = input
        .as_bytes()
        .iter()
        .position(|byte| !is_path_separator(*byte))
        .unwrap_or(input.len());
    &input[start..]
}

fn preferred_dir_sep(context: &EvalContext<'_>, path: &str) -> char {
    if path.contains('\\') {
        '\\'
    } else if path.contains('/') {
        '/'
    } else {
        context.metadata.dir_sep.chars().next().unwrap_or('\\')
    }
}

fn normalize_path(context: &EvalContext<'_>, input: &str) -> String {
    if input.is_empty() {
        return String::new();
    }
    let separator = context.metadata.dir_sep.chars().next().unwrap_or('\\');
    let root_len = path_root_length(input);
    let mut parts: Vec<&str> = Vec::new();
    let mut index = root_len;
    let bytes = input.as_bytes();
    while index < bytes.len() {
        while index < bytes.len() && is_path_separator(bytes[index]) {
            index += 1;
        }
        let start = index;
        while index < bytes.len() && !is_path_separator(bytes[index]) {
            index += 1;
        }
        let part = &input[start..index];
        if part.is_empty() || part == "." {
            continue;
        }
        if part == ".." {
            if parts.last().is_some_and(|last| *last != "..") {
                parts.pop();
            } else if root_len == 0 {
                parts.push(part);
            }
        } else {
            parts.push(part);
        }
    }

    let mut out = input[..root_len]
        .chars()
        .map(|character| {
            if matches!(character, '\\' | '/') {
                separator
            } else {
                character
            }
        })
        .collect::<String>();
    for (part_index, part) in parts.iter().enumerate() {
        if (!out.is_empty()
            && out
                .as_bytes()
                .last()
                .is_some_and(|byte| !is_path_separator(*byte)))
            || (out.is_empty() && part_index > 0)
        {
            out.push(separator);
        }
        out.push_str(part);
    }
    if out.is_empty() && root_len == 0 {
        ".".to_owned()
    } else {
        out
    }
}

fn prepend_env(context: &EvalContext<'_>, current: &str, entry: &str) -> String {
    match (entry.is_empty(), current.is_empty()) {
        (true, _) => current.to_owned(),
        (_, true) => entry.to_owned(),
        _ => format!("{entry}{}{current}", context.metadata.path_sep),
    }
}

fn append_env(context: &EvalContext<'_>, current: &str, entry: &str) -> String {
    match (entry.is_empty(), current.is_empty()) {
        (true, _) => current.to_owned(),
        (_, true) => entry.to_owned(),
        _ => format!("{current}{}{entry}", context.metadata.path_sep),
    }
}

fn remove_env(context: &EvalContext<'_>, current: &str, entry: &str) -> String {
    split_env_list(context, current)
        .into_iter()
        .filter(|part| *part != entry)
        .collect::<Vec<_>>()
        .join(&context.metadata.path_sep)
}

fn unique_env(context: &EvalContext<'_>, current: &str) -> String {
    let mut seen = BTreeSet::new();
    let mut kept = Vec::new();
    for part in split_env_list(context, current) {
        if seen.insert(part) {
            kept.push(part);
        }
    }
    kept.join(&context.metadata.path_sep)
}

fn split_env_list<'a>(context: &EvalContext<'_>, current: &'a str) -> Vec<&'a str> {
    if current.is_empty() {
        Vec::new()
    } else {
        current.split(&context.metadata.path_sep).collect()
    }
}

fn is_ident_start(byte: u8) -> bool {
    byte.is_ascii_alphabetic() || byte == b'_'
}

fn is_ident_continue(byte: u8) -> bool {
    is_ident_start(byte) || byte.is_ascii_digit()
}

fn is_path_separator(byte: u8) -> bool {
    matches!(byte, b'\\' | b'/')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn metadata() -> Metadata {
        Metadata {
            exe_path: r"C:\tools\demo.exe".into(),
            exe_dir: r"C:\tools".into(),
            exe_filename: "demo.exe".into(),
            exe_filename_noext: "demo".into(),
            exe_ext: "exe".into(),
            exe_ext_dot: ".exe".into(),
            exe_drive: "C:".into(),
            exe_root: r"C:\".into(),
            args0: "demo.exe".into(),
            cwd: r"C:\work".into(),
            temp_dir: r"C:\Temp".into(),
            home_dir: r"C:\Users\demo".into(),
            appdata_dir: r"C:\Users\demo\AppData\Roaming".into(),
            localappdata_dir: r"C:\Users\demo\AppData\Local".into(),
            programdata_dir: r"C:\ProgramData".into(),
            program_files_dir: r"C:\Program Files".into(),
            program_files_x86_dir: r"C:\Program Files (x86)".into(),
            documents_dir: r"C:\Users\demo\Documents".into(),
            downloads_dir: r"C:\Users\demo\Downloads".into(),
            desktop_dir: r"C:\Users\demo\Desktop".into(),
            os: "windows".into(),
            arch: "x86_64".into(),
            dir_sep: "\\".into(),
            path_sep: ";".into(),
        }
    }

    fn evaluate_with(
        input: &str,
        environment: &mut EnvMap,
        arguments: &[OsString],
        strictness: Strictness,
    ) -> Result<Value> {
        let metadata = metadata();
        evaluate(
            input,
            &mut EvalContext {
                metadata: &metadata,
                env: environment,
                args: arguments,
                strictness,
            },
        )
    }

    #[test]
    fn tokenizer_handles_identifiers_strings_integers_and_punctuation() {
        let tokens = tokenize(r#"args[1:end-1]:join("x\ny")"#).unwrap();
        let tags = tokens.iter().map(|token| token.tag).collect::<Vec<_>>();
        assert_eq!(
            tags,
            vec![
                TokenTag::Identifier,
                TokenTag::OpenBracket,
                TokenTag::Integer,
                TokenTag::Colon,
                TokenTag::Identifier,
                TokenTag::Minus,
                TokenTag::Integer,
                TokenTag::CloseBracket,
                TokenTag::Colon,
                TokenTag::Identifier,
                TokenTag::OpenParen,
                TokenTag::String,
                TokenTag::CloseParen,
                TokenTag::Eof,
            ]
        );
        assert_eq!(tokens[11].string, "x\ny");
    }

    #[test]
    fn parser_builds_env_lookup_with_nested_transform_argument() {
        let expression =
            parse(r#"env["PATH"]:prepend_env(exe_dir:parent:join("python"))"#).unwrap();
        assert_eq!(expression.source, Source::Env("PATH".into()));
        assert_eq!(expression.transforms.len(), 1);
        let Transform::Named(transform) = &expression.transforms[0] else {
            panic!("expected named transform");
        };
        assert_eq!(transform.name, "prepend_env");
        assert!(matches!(transform.argument, Some(Argument::Expression(_))));
    }

    #[test]
    fn evaluates_base_values_and_path_transforms() {
        let mut env = EnvMap::default();
        assert_eq!(
            evaluate_with(
                "exe_path:parent:filename",
                &mut env,
                &[],
                Strictness::default()
            )
            .unwrap(),
            Value::String(r"C:\tools".into())
        );
        assert_eq!(
            evaluate_with("exe_path:ext", &mut env, &[], Strictness::default()).unwrap(),
            Value::String("exe".into())
        );
        assert_eq!(
            evaluate_with(
                r#"exe_dir:join("..\\app"):normalize"#,
                &mut env,
                &[],
                Strictness::default()
            )
            .unwrap(),
            Value::String(r"C:\app".into())
        );
    }

    #[test]
    fn evaluates_string_transforms_and_json_escaping() {
        let mut env = EnvMap::default();
        env.put("NAME".into(), " Demo\n\t\"\\ ".into());
        assert_eq!(
            evaluate_with(
                r#"env["NAME"]:trim:lower:prefix("x-"):suffix("-y"):json"#,
                &mut env,
                &[],
                Strictness::default()
            )
            .unwrap(),
            Value::String(r#"x-demo\n\t\"\\-y"#.into())
        );
    }

    #[test]
    fn environment_lookups_default_empty_and_can_be_strict() {
        let mut env = EnvMap::default();
        assert_eq!(
            evaluate_with(r#"env["MISSING"]"#, &mut env, &[], Strictness::default()).unwrap(),
            Value::String(String::new())
        );
        assert!(matches!(
            evaluate_with(
                r#"env["MISSING"]"#,
                &mut env,
                &[],
                Strictness {
                    error_on_missing_env: true,
                    error_on_arg_out_of_bounds: false,
                }
            ),
            Err(Error::MissingEnvironmentVariable)
        ));
    }

    #[test]
    fn argument_indexing_and_slicing_are_one_based_and_inclusive() {
        let args = ["10", "20", "30", "40", "50", "60"].map(OsString::from);
        let mut env = EnvMap::default();
        assert_eq!(
            evaluate_with("args[1]", &mut env, &args, Strictness::default()).unwrap(),
            Value::String("10".into())
        );
        assert_eq!(
            evaluate_with("args[end-1]", &mut env, &args, Strictness::default()).unwrap(),
            Value::String("50".into())
        );
        assert_eq!(
            evaluate_with("args[1:2:end]", &mut env, &args, Strictness::default()).unwrap(),
            Value::List(vec!["10".into(), "30".into(), "50".into()])
        );
        assert_eq!(
            evaluate_with("args[end:-1:1]", &mut env, &args, Strictness::default()).unwrap(),
            Value::List(vec![
                "60".into(),
                "50".into(),
                "40".into(),
                "30".into(),
                "20".into(),
                "10".into()
            ])
        );
        assert_eq!(
            evaluate_with("args[end:-2:1]", &mut env, &args, Strictness::default()).unwrap(),
            Value::List(vec!["60".into(), "40".into(), "20".into()])
        );
        assert_eq!(
            evaluate_with("args[1:999999]", &mut env, &args, Strictness::default()).unwrap(),
            Value::List(args.to_vec())
        );
        assert_eq!(
            evaluate_with("args[10]", &mut env, &args, Strictness::default()).unwrap(),
            Value::String(String::new())
        );
        assert!(matches!(
            evaluate_with("args[0]", &mut env, &args, Strictness::default()),
            Err(Error::IndexOutOfBounds)
        ));
        assert!(matches!(
            evaluate_with(
                "args[10]",
                &mut env,
                &args,
                Strictness {
                    error_on_missing_env: false,
                    error_on_arg_out_of_bounds: true,
                }
            ),
            Err(Error::ArgumentOutOfBounds)
        ));
    }

    #[test]
    fn argument_indexes_can_feed_string_transforms() {
        let args = ["alpha", r#"C:\Input\demo.txt"#].map(OsString::from);
        let mut env = EnvMap::default();
        assert_eq!(
            evaluate_with("args[2]:filename", &mut env, &args, Strictness::default()).unwrap(),
            Value::String("demo.txt".into())
        );
    }

    #[test]
    fn args_as_json_emits_minimally_escaped_json_array() {
        let args = [
            "alpha",
            "two words",
            "a'b",
            "x\"y",
            "a&b|c<d>e",
            "percent%bang!caret^",
            "line\r\nnext",
            "tab\tnul\0slash\\",
            "dollar$backtick`semi;paren()",
        ]
        .map(OsString::from);
        let mut env = EnvMap::default();
        assert_eq!(
            evaluate_with("args_as_json", &mut env, &args, Strictness::default()).unwrap(),
            Value::String(
                r#"["alpha","two words","a\u0027b","x\u0022y","a&b|c<d>e","percent%bang!caret^","line\u000d\u000anext","tab\u0009nul\u0000slash\u005c","dollar\u0024backtick\u0060semi;paren()"]"#
                    .into()
            )
        );
    }

    #[test]
    fn args_as_json_uses_fixed_unicode_escapes() {
        let args = ["plain", "a'b$`\\\n", "é😀"].map(OsString::from);
        let mut env = EnvMap::default();
        assert_eq!(
            evaluate_with("args_as_json", &mut env, &args, Strictness::default()).unwrap(),
            Value::String(
                r#"["plain","a\u0027b\u0024\u0060\u005c\u000a","\u00e9\ud83d\ude00"]"#.into()
            )
        );
    }

    #[cfg(windows)]
    #[test]
    fn args_as_json_preserves_unpaired_utf16_units() {
        use std::os::windows::ffi::OsStringExt;

        let args = [OsString::from_wide(&[0xd800, b'A' as u16])];
        let mut env = EnvMap::default();
        assert_eq!(
            evaluate_with("args_as_json", &mut env, &args, Strictness::default()).unwrap(),
            Value::String(r#"["\ud800A"]"#.into())
        );
        assert!(matches!(
            evaluate_with("args[1]", &mut env, &args, Strictness::default()),
            Err(Error::ArgumentMustBeUnicode)
        ));
    }

    #[test]
    fn environment_list_transforms_preserve_order() {
        let mut env = EnvMap::default();
        env.put("PATH".into(), "a;b;a;c".into());
        assert_eq!(
            evaluate_with(
                r#"env["PATH"]:remove_env("b"):unique_env:prepend_env("z"):append_env("q")"#,
                &mut env,
                &[],
                Strictness::default()
            )
            .unwrap(),
            Value::String("z;a;c;q".into())
        );
    }

    #[test]
    fn path_and_env_helpers_return_owned_results() {
        let mut env = EnvMap::default();
        let metadata = metadata();
        let context = EvalContext {
            metadata: &metadata,
            env: &mut env,
            args: &[],
            strictness: Strictness::default(),
        };
        assert_eq!(normalize_path(&context, r#"C:\A\.\B\..\C"#), r#"C:\A\C"#);
        assert_eq!(
            remove_env(&context, r#"C:\A;C:\B;C:\A"#, r#"C:\B"#),
            r#"C:\A;C:\A"#
        );
        assert_eq!(unique_env(&context, r#"C:\A;C:\B;C:\A"#), r#"C:\A;C:\B"#);
    }

    #[test]
    fn invalid_syntax_names_and_types_fail_explicitly() {
        let mut env = EnvMap::default();
        assert!(matches!(
            evaluate_with("unknown", &mut env, &[], Strictness::default()),
            Err(Error::UnknownBase)
        ));
        assert!(matches!(
            evaluate_with("exe_dir:nope", &mut env, &[], Strictness::default()),
            Err(Error::UnknownTransform)
        ));
        assert!(matches!(
            evaluate_with("args:lower", &mut env, &[], Strictness::default()),
            Err(Error::WrongTransformType)
        ));
        assert!(matches!(
            evaluate_with("args:nope", &mut env, &[], Strictness::default()),
            Err(Error::UnknownTransform)
        ));
        assert!(matches!(
            evaluate_with("args[1:0:end]", &mut env, &[], Strictness::default()),
            Err(Error::ZeroSliceStep)
        ));
    }
}
