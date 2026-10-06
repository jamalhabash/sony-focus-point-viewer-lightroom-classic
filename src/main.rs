use clap::{Parser, Subcommand, ValueEnum};
use focuspoint::app::{self, RenderOpts};
use focuspoint::output::{Report, Value};
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
        /// Directory for the output JPEGs (created if missing).
        #[arg(long)]
        out_dir: PathBuf,
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
            source,
            size,
            crop_size,
            format,
        } => {
            let opts = RenderOpts {
                out_dir: &out_dir,
                source: source.as_deref(),
                size,
                crop_size,
            };
            emit(&app::render_cmd(&file, &opts), format)
        }
    }
}
