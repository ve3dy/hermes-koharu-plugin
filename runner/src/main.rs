//! Headless batch runner for Koharu, used by hermes-koharu-plugin.
//!
//! scripts/install.sh copies this crate into the upstream source tree as
//! `crates/koharu-batch` (the workspace picks up `crates/*`) and builds it. No
//! upstream file is modified. It runs the full pipeline (detect → OCR →
//! translate → inpaint → render) on a set of images in one process, so each
//! model loads once, and writes one PNG per page.
//!
//! Settings come from the desktop app's `~/.koharu/config.toml` (pipeline
//! models, translation model/provider, target language), so headless runs match
//! what the desktop app would produce. `--target-language` / `--instructions`
//! override for this run only. The file is never written.
//!
//! stdout: one JSON object per line. `{"event":"start","pages":N}` first,
//! `{"event":"progress",...}` while running,
//! then `{"event":"done","ok":true,"pages":[{"input","output"}],...}`.
//! Errors: `{"event":"done","ok":false,"error":"..."}` and exit code 1.

use std::{
    collections::BTreeMap,
    fs,
    io::Write as _,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context as _, Result, bail};
use clap::Parser;
use koharu_config::Config;
use koharu_pipeline::{Committer, Operation, Pipeline, PipelineConfig, Progress, Request, Scope, StageOutput};
use koharu_rasterizer::{RasterOptions, Rasterizer};
use koharu_renderer::Renderer;
use koharu_scene::{AssetInput, AssetMetadata, AssetRole, At, PageDraft, Session};
use koharu_translator::{Language, ProvidersConfig};

const IMAGE_EXTENSIONS: &[&str] = &["png", "jpg", "jpeg", "webp"];

#[derive(Debug, Parser)]
#[command(version, about = "Translate manga pages headlessly with Koharu's pipeline")]
struct Arguments {
    /// Image files or directories (non-recursive), processed in natural order.
    #[arg(required = true)]
    inputs: Vec<PathBuf>,

    /// Directory for the rendered pages (created if missing).
    #[arg(short, long)]
    output: PathBuf,

    /// Override the target language from ~/.koharu/config.toml for this run.
    #[arg(long)]
    target_language: Option<Language>,

    /// Extra translation instructions for this run, added after the configured ones.
    #[arg(long)]
    instructions: Option<String>,

    /// Force CPU even if a GPU is available.
    #[arg(long)]
    cpu: bool,
}

struct SessionCommitter<'a>(&'a mut Session);

#[async_trait::async_trait]
impl Committer for SessionCommitter<'_> {
    async fn commit(&mut self, output: StageOutput) -> Result<koharu_scene::Snapshot> {
        Ok(self.0.commit(output.patch).await?.snapshot)
    }
}

fn emit(value: serde_json::Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

#[tokio::main]
async fn main() {
    let started = Instant::now();
    match run(Arguments::parse()).await {
        Ok(pages) => emit(serde_json::json!({
            "event": "done",
            "ok": true,
            "pages": pages,
            "elapsed_s": started.elapsed().as_secs_f64(),
        })),
        Err(error) => {
            emit(serde_json::json!({"event": "done", "ok": false, "error": format!("{error:#}")}));
            std::process::exit(1);
        }
    }
}

async fn run(arguments: Arguments) -> Result<Vec<serde_json::Value>> {
    let output_dir = arguments.output.clone();
    let inputs = collect_inputs(&arguments.inputs)?;
    emit(serde_json::json!({"event": "start", "pages": inputs.len()}));
    fs::create_dir_all(&output_dir)
        .with_context(|| format!("failed to create {}", output_dir.display()))?;

    initialize_with_retry().await;

    let mut pipeline_config: PipelineConfig = PipelineConfig::load()?.read()?.clone();
    if let Some(language) = arguments.target_language {
        pipeline_config.translation.target_language = language;
    }
    if let Some(extra) = arguments.instructions.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        let combined = match pipeline_config.translation.instructions.as_deref().map(str::trim) {
            Some(base) if !base.is_empty() => format!("{base}\n\n{extra}"),
            _ => extra.to_owned(),
        };
        pipeline_config.translation.instructions = Some(combined);
    }

    let mut session = Session::memory().await?;
    let mut pages = Vec::with_capacity(inputs.len());
    for input in &inputs {
        pages.push(add_page(&mut session, input).await?);
    }

    let pipeline = Pipeline::from_config(
        Config::memory(pipeline_config),
        ProvidersConfig::load()?,
        koharu_ml::device(arguments.cpu),
    )?;
    let snapshot = session.snapshot();
    let mut committer = SessionCommitter(&mut session);
    let report = pipeline
        .execute(
            snapshot,
            Request {
                operation: Operation::Full,
                scope: Scope::Pages(pages.clone()),
                progress: Some(Arc::new(|event| {
                    if let Progress::Finished { stage, model, elapsed, .. } = event {
                        emit(serde_json::json!({
                            "event": "progress",
                            "stage": stage.to_string(),
                            "model": model,
                            "elapsed_s": elapsed.as_secs_f64(),
                        }));
                    }
                })),
                ..Request::default()
            },
            &mut committer,
        )
        .await?;
    if report.completed < report.total {
        bail!("pipeline stopped after {} of {} steps", report.completed, report.total);
    }

    let renderer = Renderer::new()?;
    let rasterizer = Rasterizer::new()?;
    let snapshot = session.snapshot();
    let mut written = Vec::with_capacity(pages.len());
    for (page, input) in pages.iter().zip(&inputs) {
        let frame = renderer.render(&snapshot, *page).await?;
        let raster = rasterizer.rasterize(&frame.raster_frame()?, RasterOptions::default())?;
        let stem = input.file_stem().and_then(|s| s.to_str()).unwrap_or("page");
        let output = output_dir.join(format!("{stem}.png"));
        raster
            .image
            .save(&output)
            .with_context(|| format!("failed to write {}", output.display()))?;
        written.push(serde_json::json!({"input": input, "output": output}));
    }
    Ok(written)
}

async fn add_page(session: &mut Session, input: &Path) -> Result<koharu_scene::EntityId> {
    let source = fs::read(input).with_context(|| format!("failed to read {}", input.display()))?;
    let decoded = image::load_from_memory(&source)
        .with_context(|| format!("failed to decode {}", input.display()))?;
    let name = input.file_name().and_then(|n| n.to_str()).unwrap_or("page");
    let mut page = None;
    let patch = session.snapshot().patch(|edit| {
        let id = edit.add_page(
            PageDraft::new(name, f64::from(decoded.width()), f64::from(decoded.height())),
            At::End,
        )?;
        edit.set_asset(
            id,
            &AssetRole::new("source")?,
            AssetInput::new(
                Arc::<[u8]>::from(source),
                media_type(input),
                AssetMetadata {
                    width: Some(decoded.width()),
                    height: Some(decoded.height()),
                    attributes: BTreeMap::new(),
                },
            ),
        )?;
        page = Some(id);
        Ok(())
    })?;
    session.commit(patch).await?;
    Ok(page.expect("page ID is assigned by the edit"))
}

fn collect_inputs(inputs: &[PathBuf]) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    for input in inputs {
        if input.is_dir() {
            let mut entries: Vec<PathBuf> = fs::read_dir(input)
                .with_context(|| format!("failed to list {}", input.display()))?
                .filter_map(|entry| entry.ok().map(|e| e.path()))
                .filter(|path| path.is_file() && is_image(path))
                .collect();
            entries.sort_by(|a, b| natural_key(a).cmp(&natural_key(b)));
            files.extend(entries);
        } else if input.is_file() {
            files.push(input.clone());
        } else {
            bail!("not found: {}", input.display());
        }
    }
    if files.is_empty() {
        bail!("no images found (supported: {})", IMAGE_EXTENSIONS.join(", "));
    }
    Ok(files)
}

fn is_image(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| IMAGE_EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()))
}

/// `page2` sorts before `page10`.
fn natural_key(path: &Path) -> Vec<(u64, String)> {
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("").to_lowercase();
    let mut key = Vec::new();
    let mut digits = String::new();
    let mut text = String::new();
    for ch in name.chars() {
        if ch.is_ascii_digit() {
            if !text.is_empty() {
                key.push((0, std::mem::take(&mut text)));
            }
            digits.push(ch);
        } else {
            if !digits.is_empty() {
                key.push((digits.parse().unwrap_or(u64::MAX), String::new()));
                digits.clear();
            }
            text.push(ch);
        }
    }
    if !digits.is_empty() {
        key.push((digits.parse().unwrap_or(u64::MAX), String::new()));
    }
    if !text.is_empty() {
        key.push((0, text));
    }
    key
}

fn media_type(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).map(str::to_ascii_lowercase).as_deref() {
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("webp") => "image/webp",
        _ => "image/png",
    }
}

async fn initialize_with_retry() {
    let mut delay = Duration::from_secs(1);
    let mut attempt = 0_u32;
    loop {
        attempt += 1;
        match koharu_ml::init().await {
            Ok(()) => return,
            Err(error) if attempt < 6 => {
                emit(serde_json::json!({"event": "progress", "stage": "init", "retry": attempt, "error": format!("{error:#}")}));
                tokio::time::sleep(delay).await;
                delay = (delay * 2).min(Duration::from_secs(30));
            }
            Err(error) => {
                emit(serde_json::json!({"event": "done", "ok": false, "error": format!("runtime init failed: {error:#}")}));
                std::process::exit(1);
            }
        }
    }
}
