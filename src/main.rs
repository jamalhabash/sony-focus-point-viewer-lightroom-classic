use clap::{Parser, Subcommand, ValueEnum};
use focuspoint::app::{self, RenderOpts};
use focuspoint::batch::{self, BatchOpts};
use focuspoint::output::{Report, Value};
use std::io::Read;
use std::path::PathBuf;
use std::process::ExitCode;

#[derive(Parser)]
#[command(
    name = "focuspoint",
    version,
    about = "Show the autofocus point of Sony (a7 IV) photos"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Clone, Copy, ValueEnum)]
enum Format {
    Json,
    Kv,
}

#[derive(Subcommand)]
enum Cmd {
    /// Print focus metadata.
    Info {
        file: PathBuf,
        #[arg(long, value_enum, default_value = "json")]
        format: Format,
    },
    /// Print focus metadata and write overview + crop JPEGs.
    Render {
        file: PathBuf,
        /// Directory for uniquely named output JPEGs (created if missing).
        #[arg(long, required_unless_present = "cache_dir")]
        out_dir: Option<PathBuf>,
        /// Persistent render cache (created if missing). Bypassed with
        /// --source; then outputs go to --out-dir, or <cache-dir>/uncached.
        #[arg(long)]
        cache_dir: Option<PathBuf>,
        /// Full, uncropped frame in display orientation (e.g. a Lightroom preview).
        #[arg(long)]
        source: Option<PathBuf>,
        /// Long edge of the overview image in pixels.
        #[arg(long, default_value_t = 1600, value_parser = clap::value_parser!(u32).range(16..=20000))]
        size: u32,
        /// Edge length of the 1:1 crop around the focus point in pixels.
        #[arg(long, default_value_t = 800, value_parser = clap::value_parser!(u32).range(16..=20000))]
        crop_size: u32,
        #[arg(long, value_enum, default_value = "json")]
        format: Format,
    },
    /// Render many files into the cache in parallel. Prints one block per
    /// input file, in input order: `file=<path>`, the `render` keys, `---`.
    Batch {
        /// Render cache directory (created if missing).
        #[arg(long)]
        cache_dir: PathBuf,
        /// File with one input path per line (default: read stdin).
        #[arg(long)]
        list: Option<PathBuf>,
        /// Long edge of the overview image in pixels.
        #[arg(long, default_value_t = 1600, value_parser = clap::value_parser!(u32).range(16..=20000))]
        size: u32,
        /// Edge length of the 1:1 crop around the focus point in pixels.
        #[arg(long, default_value_t = 800, value_parser = clap::value_parser!(u32).range(16..=20000))]
        crop_size: u32,
        /// Worker threads [default: max(2, cores/2)].
        #[arg(long, value_parser = clap::value_parser!(u32).range(1..=256))]
        jobs: Option<u32>,
        #[arg(long, value_enum, default_value = "kv")]
        format: Format,
        /// After the batch, delete least-recently-used cache entries until
        /// the cache is at most this big.
        #[arg(long, default_value_t = 2048)]
        cache_max_mb: u64,
    },
}

fn emit(r: &Report, f: Format) -> ExitCode {
    let out = match f {
        Format::Json => r.to_json(),
        Format::Kv => r.to_kv(),
    };
    print!("{out}");
    match r.get("status") {
        Some(Value::Str(s)) if s == "error" => ExitCode::from(1),
        _ => ExitCode::SUCCESS,
    }
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Info { file, format } => emit(&app::info(&file), format),
        Cmd::Render {
            file,
            out_dir,
            cache_dir,
            source,
            size,
            crop_size,
            format,
        } => {
            let opts = RenderOpts {
                out_dir: out_dir.as_deref(),
                cache_dir: cache_dir.as_deref(),
                source: source.as_deref(),
                size,
                crop_size,
                parallel: true,
            };
            emit(&app::render_cmd(&file, &opts), format)
        }
        Cmd::Batch {
            cache_dir,
            list,
            size,
            crop_size,
            jobs,
            format,
            cache_max_mb,
        } => {
            let text = match &list {
                Some(p) => std::fs::read(p).map_err(|e| format!("--list {}: {e}", p.display())),
                None => {
                    let mut b = Vec::new();
                    std::io::stdin()
                        .read_to_end(&mut b)
                        .map(|_| b)
                        .map_err(|e| format!("reading stdin: {e}"))
                }
            };
            let text = match text {
                Ok(t) => t,
                Err(e) => {
                    eprintln!("focuspoint: {e}");
                    return ExitCode::from(2);
                }
            };
            let paths = batch::parse_list(&String::from_utf8_lossy(&text));
            let opts = BatchOpts {
                cache_dir: &cache_dir,
                size,
                crop_size,
                jobs: jobs.map_or_else(batch::default_jobs, |j| j as usize),
                json: matches!(format, Format::Json),
                cache_max_bytes: cache_max_mb.saturating_mul(1024 * 1024),
            };
            let stdout = std::io::stdout();
            match batch::run(&paths, &opts, &mut stdout.lock()) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => {
                    eprintln!("focuspoint: writing output: {e}");
                    ExitCode::from(1)
                }
            }
        }
    }
}
