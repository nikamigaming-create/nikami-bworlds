use esplugin::{GameId, ParseOptions, Plugin};
use serde::Serialize;
use std::env;
use std::error::Error;
use std::path::{Path, PathBuf};

#[derive(Serialize)]
struct PluginAudit {
    path: PathBuf,
    filename: Option<String>,
    masters: Vec<String>,
    is_master: bool,
    header_version: Option<f32>,
    record_and_group_count: Option<u32>,
    override_records: usize,
    overlaps_with_previous: Vec<String>,
}

#[derive(Serialize)]
struct Audit {
    status: &'static str,
    game: &'static str,
    parser: &'static str,
    plugins: Vec<PluginAudit>,
}

fn audit(paths: &[PathBuf]) -> Result<Audit, Box<dyn Error>> {
    let mut plugins = Vec::with_capacity(paths.len());
    for path in paths {
        let mut plugin = Plugin::new(GameId::FalloutNV, Path::new(path));
        plugin.parse_file(ParseOptions::whole_plugin())?;
        plugins.push(plugin);
    }

    let mut audits = Vec::with_capacity(plugins.len());
    for (index, plugin) in plugins.iter().enumerate() {
        let mut overlaps = Vec::new();
        for previous in &plugins[..index] {
            if plugin.overlaps_with(previous)? {
                overlaps.push(
                    previous
                        .filename()
                        .unwrap_or_else(|| previous.path().display().to_string()),
                );
            }
        }

        audits.push(PluginAudit {
            path: plugin.path().to_path_buf(),
            filename: plugin.filename(),
            masters: plugin.masters()?,
            is_master: plugin.is_master_file(),
            header_version: plugin.header_version(),
            record_and_group_count: plugin.record_and_group_count(),
            override_records: plugin.count_override_records()?,
            overlaps_with_previous: overlaps,
        });
    }

    Ok(Audit {
        status: "pass",
        game: "FalloutNV",
        parser: "Ortham/esplugin@e01c5b01e2c0d647b40453f01353eef29c4db691",
        plugins: audits,
    })
}

fn main() -> Result<(), Box<dyn Error>> {
    let paths: Vec<PathBuf> = env::args_os().skip(1).map(PathBuf::from).collect();
    if paths.is_empty() {
        return Err("usage: fnv-esplugin-audit <plugin.esm|plugin.esp>...".into());
    }

    let result = audit(&paths)?;
    println!("{}", serde_json::to_string_pretty(&result)?);
    Ok(())
}
